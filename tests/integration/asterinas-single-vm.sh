#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
mkdir -p "$repo_root/.work/tmp"
work="$(mktemp -d "$repo_root/.work/tmp/asterinas-single-vm.XXXXXXXX")"
owner=""
cleanup() {
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
        kill -TERM -- "-$owner" 2>/dev/null || true
        wait "$owner" 2>/dev/null || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
setsid env XSH_TEST=tests/xsh/stdlib/numeric.xsh make -C "$repo_root" asterinas-test >"$work/run.log" 2>&1 &
owner=$!
seen=0
maximum=0
while kill -0 "$owner" 2>/dev/null; do
    count="$(ps -C firecracker -o args= | rg -F -c -- "$repo_root/.out/asterinas-firecracker/builds/" || true)"
    count="${count:-0}"
    (( count > maximum )) && maximum="$count"
    (( count > 0 )) && seen=1
    sleep 0.1
done
status=0
wait "$owner" || status=$?
owner=""
if (( status != 0 || seen != 1 || maximum != 1 )); then
    cat "$work/run.log" >&2
    printf 'expected one owned Firecracker, observed maximum %s and status %s\n' "$maximum" "$status" >&2
    exit 1
fi
printf 'one Firecracker completed the selected numeric proof\n'
