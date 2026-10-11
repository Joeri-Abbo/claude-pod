#!/usr/bin/env bash
set -euo pipefail

workflow="${BASH_SOURCE[0]%/*}/workflows/bump-claude-docker.yml"
script=$(sed -n '/^          set -euo pipefail$/,/^          current=/{
  /^          current=/d
  s/^          //
  p
}' "$workflow")
gh() { printf '%s\n' "$TEST_TAG"; }
export -f gh

for TEST_TAG in v0.3.5 v12.34.56; do
  export TEST_TAG
  bash -c "$script"
done
for TEST_TAG in 'v0.3.5#/;e(id);#' 'v0.3.5/evil' 'v0.3.5&evil' \
    'v0.3.5-rc.1' 'v0.3.5+build' '0.3.5' 'v0.3' '' $'v0.3.5\nevil'; do
  export TEST_TAG
  if bash -c "$script" >/dev/null 2>&1; then
    echo "expected release tag to be rejected: $TEST_TAG" >&2
    exit 1
  fi
done
