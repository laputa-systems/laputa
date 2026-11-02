#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# == 2 ]] || { printf 'usage: qualify-network-state.sh linux|asterinas|both CASE\n' >&2; exit 2; }
backend="$1"
selected="$2"

regression="$repo_root/asterinas/test/initramfs/src/regression/network"
witnesses=(rtnl_route_dump link_state addr_config route_config rtnl_ack rtnl_notify packet_bind packet_receive)
modes=(loopback link address route events packet)

if [[ -n "$selected" ]]; then
    known=0
    for name in "${witnesses[@]}" "${modes[@]}"; do [[ "$name" != "$selected" ]] || known=1; done
    (( known )) || { printf 'qualification: unknown network-state case: %s\n' "$selected" >&2; exit 2; }
fi
case "$backend" in linux) backends=(linux) ;; asterinas) backends=(asterinas) ;; both) backends=(linux asterinas) ;; *) exit 2 ;; esac

mkdir -p "$repo_root/.work/tmp"
export TMPDIR="$repo_root/.work/tmp"
work="$(mktemp -d "$TMPDIR/network-state.XXXXXXXX")"
failed=0

run_backends() {
    local label="$1"; shift
    local pids=() side
    for side in "${backends[@]}"; do
        mkdir -p "$work/$label-$side"
        "$@" "$side" "$work/$label-$side" > "$work/$label-$side.log" 2>&1 &
        pids+=("$!")
    done
    local index=0
    for side in "${backends[@]}"; do
        if ! wait "${pids[$index]}"; then
            failed=1
            printf 'qualification: %s failed on %s\n' "$label" "$side" >&2
            tail -n 20 "$work/$label-$side.log" >&2
        fi
        index=$((index + 1))
    done
}

witness() { bash "$repo_root/infra/asterinas/run-witness.sh" "$2" "$regression/$1.c" "$3"; }
guest_mode() { LAPUTA_GUEST_NETWORK=tap bash "$repo_root/infra/asterinas/run-guest-case.sh" "$2" "$repo_root/guest/asterinas/network-state" "$1" "$3"; }

transcript() {
    sed 's/\x1b\[[0-9;]*m//g' "$1/console.log" | tr -d '\r' | rg '^NET_' | rg -v '^NET_[A-Za-z0-9_]*_(ADDR|ROUTE|RULE) (\S+ )?inet6 ' || true
}

for name in "${witnesses[@]}"; do
    [[ -z "$selected" || "$selected" == "$name" ]] || continue
    run_backends "witness-$name" witness "$name"
done

for mode in "${modes[@]}"; do
    [[ -z "$selected" || "$selected" == "$mode" ]] || continue
    run_backends "mode-$mode" guest_mode "$mode"
    if [[ "$backend" == both && -s "$work/mode-$mode-linux/console.log" && -s "$work/mode-$mode-asterinas/console.log" ]]; then
        transcript "$work/mode-$mode-linux" > "$work/mode-$mode-linux.transcript"
        transcript "$work/mode-$mode-asterinas" > "$work/mode-$mode-asterinas.transcript"
        [[ -s "$work/mode-$mode-linux.transcript" ]] || { printf 'qualification: %s produced no transcript\n' "$mode" >&2; failed=1; }
        if ! diff -u "$work/mode-$mode-linux.transcript" "$work/mode-$mode-asterinas.transcript" >&2; then
            printf 'qualification: %s differs between Linux and Asterinas\n' "$mode" >&2
            failed=1
        fi
    fi
done

if (( failed )); then
    printf 'qualification: network-state failed; results kept in %s\n' "$work" >&2
    exit 1
fi
rm -rf -- "$work"
printf 'qualification: network-state passed for %s\n' "$backend"
