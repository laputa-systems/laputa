#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 && "$2" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'usage: select-xsh-target.sh REPO_ROOT SOURCE_INPUTS_SHA256\n' >&2
    exit 2
}
repo_root="$(cd "$1" && pwd -P)"
inputs_sha256="$2"
cache_root="$repo_root/.out/asterinas-firecracker/xsh-targets"
link="$repo_root/.out/xsh-target"
target="$cache_root/$inputs_sha256"
mkdir -p "$target"
if [[ -e "$link" && ! -L "$link" ]]; then
    [[ -d "$link" ]] || { printf 'asterinas-xsh: target cache is not a directory: %s\n' "$link" >&2; exit 1; }
    legacy="$(mktemp -d "$cache_root/legacy.XXXXXXXX")"
    rmdir "$legacy"
    mv "$link" "$legacy"
fi
[[ ! -L "$link" || "$(readlink "$link")" != "$target" ]] || exit 0
temporary="$link.tmp.$$"
trap 'rm -f -- "$temporary"' EXIT
ln -s "$target" "$temporary"
mv -Tf "$temporary" "$link"
