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
git --git-dir="$cache_dir" archive --format=tar "$XSH_COMMIT" | tar -xf - -C "$stage"
git -C "$stage" init --quiet
git -C "$stage" add --all
GIT_AUTHOR_NAME='Laputa Asterinas build' GIT_AUTHOR_EMAIL='build@laputa.invalid' \
    GIT_COMMITTER_NAME='Laputa Asterinas build' GIT_COMMITTER_EMAIL='build@laputa.invalid' \
    GIT_AUTHOR_DATE='1970-01-01T00:00:00+0000' GIT_COMMITTER_DATE='1970-01-01T00:00:00+0000' \
    git -C "$stage" -c user.name='Laputa Asterinas build' \
        -c user.email='build@laputa.invalid' commit --quiet -m 'Pinned XSH build input'
snapshot_tree="$(git -C "$stage" rev-parse HEAD^{tree})"
xsh_build_inputs_hash="$(printf '%s\n' "$snapshot_tree" | sha256sum | awk '{print $1}')"
snapshot="$snapshot_dir/$XSH_COMMIT-$xsh_build_inputs_hash"
if [[ -d "$snapshot" ]]; then
    existing_tree="$(git -C "$snapshot" rev-parse HEAD^{tree})" || fail "cached XSH snapshot is not a Git checkout: $snapshot"
    existing_changes="$(GIT_OPTIONAL_LOCKS=0 git -C "$snapshot" status --porcelain --untracked-files=all)" || \
        fail "could not validate cached XSH snapshot: $snapshot"
    [[ "$existing_tree" == "$snapshot_tree" && -z "$existing_changes" ]] || \
        fail "cached XSH snapshot does not match the locked source: $snapshot"
    chmod -R u+w "$stage"
    rm -rf "$stage"
else
    chmod -R a-w "$stage"
    mv "$stage" "$snapshot"
fi
printf '%s\n%s\n' "$snapshot" "$xsh_build_inputs_hash"
