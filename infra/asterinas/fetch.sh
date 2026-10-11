#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
unset XSH_BIN_DIR XSH_HOST
xsh_snapshot_output="$(bash "$repo_root/infra/asterinas/prepare-xsh.sh")"
readarray -t xsh_snapshot <<< "$xsh_snapshot_output"
[[ ${#xsh_snapshot[@]} -eq 2 ]] || {
    printf 'asterinas-fetch: pinned XSH snapshot helper returned invalid output\n' >&2
    exit 1
}
xsh_root="${xsh_snapshot[0]}"
make_args=("XSH_ROOT=$xsh_root" "XSH_BIN_DIR=$repo_root/.out/host/x86_64" ARCH=x86_64)

make -C "$repo_root" "${make_args[@]}" host-xsh
xsh_bin_dir="$repo_root/.out/host/x86_64"

export XSH_ROOT="$xsh_root"
export XSH_MODULE_PATH="$repo_root"
export XSH_HOST="${XSH_HOST:-$xsh_bin_dir/xsh}"
export PATH="$xsh_bin_dir:$PATH"
export LAPUTA_SOURCE_CACHE="${SOURCE_CACHE:-$repo_root/.cache/sources}"

make -C "$repo_root" "${make_args[@]}" fetch-seed
"$XSH_HOST" "$repo_root/pm.xsh" -- sources fetch --repo "$repo_root" --target x86_64-linux-musl llvm-toolchain
make -C "$repo_root" "${make_args[@]}" plan 'PKGS=baselayout xsh laputa-pm xinit'
"$XSH_HOST" "$repo_root/infra/asterinas/fetch-plan-sources.xsh" -- "$repo_root/.out/world/x86_64/plan.json"
bash "$repo_root/infra/asterinas/setup.sh" fetch

printf 'Fetched the pinned Asterinas and Laputa build inputs.\n'
