#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

for path in "$repo_root/.out/asterinas-firecracker" "$repo_root/.cache/asterinas"; do
    if [[ -e "$path" || -L "$path" ]]; then
        chmod -R u+w "$path"
        rm -rf -- "$path"
    fi
done
