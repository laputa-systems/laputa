#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/inputs.lock"
cache_dir="$repo_root/.cache/asterinas/xsh.git"
snapshot_dir="$repo_root/.out/asterinas-firecracker/xsh-snapshots"

fail() {
    printf 'asterinas-xsh: %s\n' "$*" >&2
    exit 1
}

[[ "$XSH_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'XSH commit pin must be a full Git commit id'
[[ "$XSH_REPOSITORY" == https://github.com/laputa-systems/xsh.git ]] || \
    fail 'XSH repository pin is invalid'
mkdir -p "$(dirname "$cache_dir")" "$snapshot_dir"
if [[ ! -d "$cache_dir" ]]; then
    git init --bare --quiet "$cache_dir"
fi
git --git-dir="$cache_dir" rev-parse --git-dir >/dev/null 2>&1 || \
    fail "managed XSH source cache is not a Git repository: $cache_dir"
if ! git --git-dir="$cache_dir" cat-file -e "$XSH_COMMIT^{commit}" 2>/dev/null; then
    git --git-dir="$cache_dir" fetch --quiet --no-tags --depth=1 "$XSH_REPOSITORY" "$XSH_COMMIT" || \
        fail "could not fetch pinned XSH commit $XSH_COMMIT"
fi

stage="$snapshot_dir/.snapshot-$$"
rm -rf "$stage"
mkdir -p "$stage"
trap 'if [[ -d "$stage" ]]; then chmod -R u+w "$stage"; rm -rf "$stage"; fi' EXIT
git -C "$stage" init --quiet
git -C "$stage" -c gc.auto=0 -c maintenance.auto=false fetch --quiet --no-tags --depth=1 "file://$cache_dir" "$XSH_COMMIT"
git -C "$stage" -c advice.detachedHead=false checkout --quiet --detach "$XSH_COMMIT"
snapshot_tree="$(git -C "$stage" rev-parse HEAD^{tree})"
xsh_build_inputs_hash="$(printf '%s\n' "$snapshot_tree" | sha256sum | awk '{print $1}')"
snapshot="$snapshot_dir/$XSH_COMMIT-$xsh_build_inputs_hash"
if [[ -d "$snapshot" ]]; then
    existing_commit="$(git -C "$snapshot" rev-parse HEAD)" || fail "cached XSH snapshot is not a Git checkout: $snapshot"
    existing_tree="$(git -C "$snapshot" rev-parse HEAD^{tree})" || fail "cached XSH snapshot is not a Git checkout: $snapshot"
    existing_changes="$(GIT_OPTIONAL_LOCKS=0 git -C "$snapshot" status --porcelain --untracked-files=all)" || \
        fail "could not validate cached XSH snapshot: $snapshot"
    [[ "$existing_commit" == "$XSH_COMMIT" && "$existing_tree" == "$snapshot_tree" && -z "$existing_changes" ]] || \
        fail "cached XSH snapshot does not match the locked source; remove it and rerun: $snapshot"
    chmod -R u+w "$stage"
    rm -rf "$stage"
else
    chmod -R a-w "$stage"
    mv "$stage" "$snapshot"
fi
bash "$repo_root/infra/asterinas/select-xsh-target.sh" "$repo_root" "$xsh_build_inputs_hash"
printf '%s\n%s\n' "$snapshot" "$xsh_build_inputs_hash"
