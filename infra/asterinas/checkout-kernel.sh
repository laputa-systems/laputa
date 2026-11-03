#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source_dir="$repo_root/asterinas"

fail() {
    printf 'asterinas-checkout: %s\n' "$*" >&2
    exit 1
}

pin="$(git -C "$repo_root" ls-files --stage -- asterinas | awk '$1 == "160000" && $4 == "asterinas" { print $2 }')"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || fail 'asterinas is not a gitlink of this repository'
url="$(git config --file "$repo_root/.gitmodules" --get submodule.asterinas.url)" || fail 'asterinas has no url in .gitmodules'

if [[ ! -e "$source_dir/.git" ]]; then
    [[ -z "$(ls -A "$source_dir" 2>/dev/null)" ]] || fail "$source_dir is not a git checkout and is not empty"
    module_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir)/modules/asterinas"
    [[ ! -e "$module_dir" ]] || fail "$module_dir exists without a checkout; remove it to clone again"
    mkdir -p "$(dirname "$module_dir")"
    git clone --no-checkout --separate-git-dir "$module_dir" "$url" "$source_dir"
fi

if [[ "$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)" != "$pin" ]]; then
    git -C "$source_dir" cat-file -e "$pin^{commit}" 2>/dev/null || git -C "$source_dir" fetch origin "$pin"
    git -C "$source_dir" checkout --detach "$pin"
fi
