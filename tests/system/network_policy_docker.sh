#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
xsh_root="$(cd "${1:?usage: network_policy_docker.sh XSH_ROOT}" && pwd -P)"
test -x "$xsh_root/bin/xsh"
git -C "$repo_root" check-ignore -q .work/
mkdir -p "$repo_root/.work/tmp"
export TMPDIR="$repo_root/.work/tmp"
scratch="$(mktemp -d "$TMPDIR/network-policy.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

run_driver() {
    local network="$1"
    shift
    docker run --rm --pull never --network "$network" --cap-drop ALL --user "$(id -u):$(id -g)" \
        --security-opt no-new-privileges --read-only \
        --mount "type=bind,source=$xsh_root,target=/xsh,readonly" \
        --mount "type=bind,source=$repo_root,target=/laputa,readonly" \
        --env XSH_ROOT=/xsh --env XSH_MODULE_PATH=/laputa \
        --workdir /laputa xsh-test /xsh/bin/xsh \
        tests/system/fixtures/network-policy-capture.xsh "$@"
}

run_driver bridge capture > "$scratch/capture.json"
relative_capture=".work/tmp/${scratch##*/}/capture.json"
actual="$(run_driver none replay "$relative_capture")"
recorded="$(run_driver none replay tests/system/fixtures/network-policy-docker-conflict.json)"
expected="desired address is foreign; ownership cannot be inferred"
test "$actual" = "$expected"
test "$recorded" = "$expected"
printf '%s\n' 'network policy Docker capture and offline replay passed'
