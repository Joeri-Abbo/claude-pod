# claude-pod

Claude Code as a long-running Kubernetes pod: a Helm chart plus a small laptop-side helper.

- **Image**: [schubergphilis/claude-docker](https://github.com/schubergphilis/claude-docker) (Claude Code plus dev
  tooling), running as a non-root `claude` user, so `--dangerously-skip-permissions` works.
- **Sessions**: Claude runs in tmux inside the pod. Detach, close your laptop, and reattach later.
- **Files**: `claude-pod up/down` copies between your laptop and `/workspaces` over `kubectl exec`; no ports are
  opened.
- **S3**: a single-node [Garage](https://garagehq.deuxfleurs.fr) in the same namespace, with `s3sync` in the pod
  to keep copies of workspace directories in a bucket.
- **Network**: Cilium policies deny all ingress, and all egress except DNS, the S3, and what you allow.
- **Storage**: HOME (`/root`: Claude config, history) and `/workspaces` share one PVC; Garage has its own.

## Requirements

- Kubernetes with a default StorageClass (or set `storage.storageClass` / `s3.storage.storageClass`)
- [Cilium](https://cilium.io), with its DNS proxy for `egress.fqdns`. Without Cilium, set
  `networkPolicy.enabled=false`, which leaves the pods unrestricted.
- A model for Claude Code: an LLM gateway (LiteLLM, ...) or the Anthropic API
- On your laptop: `kubectl`, `helm`, `tar`, `bash`

## Install

Put your model access in a Secret:

```bash
kubectl create namespace claude-pod
kubectl -n claude-pod create secret generic llm-key --from-literal=token=sk-...
```

and write `my-values.yaml`. Via an LLM gateway such as LiteLLM in the same cluster:

```yaml
env:
  ANTHROPIC_BASE_URL: http://litellm.litellm.svc:4000
  ANTHROPIC_MODEL: claude-opus # whatever your gateway calls it
secretEnv:
  ANTHROPIC_AUTH_TOKEN: {name: llm-key, key: token}
egress:
  services:
    - {namespace: litellm, labels: {app: litellm}, port: 4000}
```

Or via the Anthropic API:

```yaml
secretEnv:
  ANTHROPIC_API_KEY: {name: llm-key, key: token}
egress:
  fqdns:
    - matchName: api.anthropic.com
```

Then:

```bash
helm install claude-pod . -n claude-pod -f my-values.yaml
ln -s "$PWD/bin/claude-pod" ~/bin/claude-pod   # any directory on your PATH
claude-pod                                     # attach to Claude
```

The first start pulls a large image, so give it a minute (`claude-pod status`).

### Values

| Key | Default | |
| --- | --- | --- |
| `image.repository` / `image.tag` | `ghcr.io/schubergphilis/claude-docker` / `v0.3.1` | |
| `uid` | `1000` | UID/GID the entrypoint drops to |
| `storage.storageClass` / `storage.size` | cluster default / `20Gi` | HOME + `/workspaces` |
| `resources` | 250m / 512Mi request, 6Gi limit | Claude pod |
| `env` | `{}` | plain env vars |
| `secretEnv` | `{}` | env vars from Secrets: `NAME: {name: <secret>, key: <key>}` |
| `s3.enabled` | `true` | in-namespace Garage + `s3sync` wiring |
| `s3.image.repository` / `s3.image.tag` | `dxflrs/garage` / `v2.4.1` | |
| `s3.bucket` | `workspaces` | |
| `s3.storage.storageClass` / `s3.storage.size` | cluster default / `20Gi` | Garage data |
| `networkPolicy.enabled` | `true` | Cilium policies; needs Cilium |
| `egress.services` | `[]` | in-cluster pods: `{namespace, labels, port}` |
| `egress.fqdns` | `[]` | external hosts: `{matchName \| matchPattern, ports: [443]}` |
| `egress.extra` | `[]` | raw CiliumNetworkPolicy egress rules |

The S3 credentials are generated on first install and reused on upgrades through Helm's `lookup`. Tools that only
render templates, such as `helm template` or Argo CD, can't look up existing Secrets, so with those you'll need to
create Secret `<release>-s3` yourself. It needs keys `access-key-id` (`GK` + 24 hex), `secret-access-key` (64 hex)
and `rpc-secret` (64 hex).

## Use

`bin/claude-pod` uses your current kube context, or `KUBECONFIG` / `CLAUDE_POD_CONTEXT`. Set
`CLAUDE_POD_NAMESPACE` and `CLAUDE_POD_RELEASE` (both default `claude-pod`) if you installed under other names.

```bash
claude-pod                        # attach to Claude (starts it if needed); Ctrl-b d detaches, Claude keeps running
claude-pod --yolo                 # start with --dangerously-skip-permissions (flags only apply to a new session)
claude-pod shell                  # bash in the pod
claude-pod exec git -C /workspaces/my-repo status

claude-pod up ./my-repo           # upload -> /workspaces/my-repo
claude-pod up notes.txt docs      # upload -> /workspaces/docs/notes.txt
claude-pod down my-repo           # download /workspaces/my-repo -> ./my-repo
claude-pod down my-repo /tmp/out  # download -> /tmp/out/my-repo
claude-pod ls [path]

claude-pod s3sync up my-repo      # /workspaces/my-repo -> s3://workspaces/my-repo
claude-pod s3sync down my-repo    # and back
claude-pod status
```

Everything runs as the `claude` user, so Claude can edit what you upload. Avoid a bare `kubectl exec`, which runs as
root, and `kubectl cp`, which keeps your laptop's UID: Claude can't edit files written either way.

### S3

Inside the pod, `s3sync up|down [path] [aws s3 sync args...]` syncs a directory under `/workspaces` (default:
the current one) with the same path in the bucket:

```bash
s3sync up                                   # push the current dir
s3sync down my-repo --delete                # pull, removing local files that aren't in the bucket
s3sync up . --dryrun --exclude 'node_modules/*'
```

To use the bucket from your laptop, port-forward and use any S3 client:

```bash
kubectl -n claude-pod port-forward svc/claude-pod-s3 3900 &
export AWS_ENDPOINT_URL=http://localhost:3900 AWS_REGION=garage \
  AWS_ACCESS_KEY_ID=$(kubectl -n claude-pod get secret claude-pod-s3 -o jsonpath='{.data.access-key-id}' | base64 -d) \
  AWS_SECRET_ACCESS_KEY=$(kubectl -n claude-pod get secret claude-pod-s3 -o jsonpath='{.data.secret-access-key}' | base64 -d)
aws s3 ls s3://workspaces/
```

The network policy only admits the Claude pod; a port-forward works because it enters the pod directly.

## Clean up

```bash
claude-pod rm my-repo                                           # one project in the workspace
claude-pod clean                                                # the whole workspace (asks first; keeps HOME)
claude-pod exec aws s3 rm --recursive s3://workspaces/my-repo   # one project in the bucket
claude-pod exec aws s3 rm --recursive s3://workspaces           # the whole bucket
```

To start completely fresh: the PVCs and the S3 Secret survive `helm uninstall` (so a reinstall picks up where you
left off) and have to be deleted explicitly:

```bash
helm uninstall claude-pod -n claude-pod
kubectl -n claude-pod delete pvc claude-pod-data claude-pod-s3-data
kubectl -n claude-pod delete secret claude-pod-s3
```

## Network access

Egress is deny-all except DNS, the S3 and what you allow, so `git clone`, `npm install` and so on fail until you
open them. Extend `egress` and `helm upgrade`:

```yaml
egress:
  fqdns:
    - matchName: github.com
    - matchPattern: "*.githubusercontent.com"
    - matchName: registry.npmjs.org
    - {matchName: example.com, ports: [80, 443]}
  extra:
    - toCIDR: [10.0.0.0/8]
```

See what gets dropped with Hubble: `hubble observe -n claude-pod --verdict DROPPED`.
