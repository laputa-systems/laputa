#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# == 3 ]] || { printf 'usage: run-udp-witness.sh asterinas|linux error|neighbor|tos-wire|dont-route RESULT_DIR\n' >&2; exit 2; }
backend="$1"
case "$2" in
    error) case_name=udp-error; source_name=udp_icmp_error ;;
    neighbor) case_name=udp-neighbor; source_name=udp_neighbor_error ;;
    tos-wire) case_name=udp-tos-wire; source_name=udp_tos_wire ;;
    dont-route) case_name=udp-dont-route; source_name=udp_dontroute ;;
    *) printf 'run-udp-witness: unknown case: %s\n' "$2" >&2; exit 2 ;;
esac
result_dir="$3"
mkdir -p "$result_dir"
result_dir="$(realpath "$result_dir")"
case_dir="$result_dir/input"
mkdir "$case_dir"
test_dir="$repo_root/asterinas/test/initramfs/src/regression"
cp "$repo_root/guest/asterinas/$case_name/entry.xsh" "$case_dir/entry.xsh"
cp "$test_dir/common/test.h" "$test_dir/network/rtnl_common.h" "$case_dir/"
sed 's|"../common/test.h"|"test.h"|' "$test_dir/network/$source_name.c" > "$case_dir/$source_name.c"
if [[ "$case_name" == udp-tos-wire ]]; then
    cp "$test_dir/network/udp_tos_peer.c" "$repo_root/guest/asterinas/$case_name/peer.sh" "$case_dir/"
fi
LAPUTA_GUEST_NETWORK=tap bash "$repo_root/infra/asterinas/run-guest-case.sh" "$backend" "$case_dir" witness "$result_dir/run"
