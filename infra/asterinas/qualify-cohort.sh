#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# == 3 ]] || { printf 'usage: qualify-cohort.sh COHORT linux|asterinas|both CASE\n' >&2; exit 2; }
cohort="$1"
backend="$2"
selected="$3"

regression="$repo_root/asterinas/test/initramfs/src/regression"
witnesses=()
case_dir=""
modes=()
tap_modes=()
compare_transcripts=0
case "$cohort" in
    device)
        witnesses=(device/block_uevent)
        ;;
    clock-abi)
        witnesses=(time/clock_adjust)
        ;;
    clock)
        witnesses=(network/udp_ancillary)
        case_dir=clock
        modes=(behind ahead frequency pause jump)
        tap_modes=(pause jump)
        ;;
    network-state)
        witnesses=(network/rtnl_route_dump network/link_state network/addr_config network/route_config network/rtnl_ack network/rtnl_notify network/packet_bind network/packet_receive network/packet_send network/packet_options)
        case_dir=network-state
        modes=(loopback link address route events packet)
        tap_modes=("${modes[@]}")
        compare_transcripts=1
        ;;
    network)
        witnesses=(fs/procfs/proc_boot_id network/udp_device)
        case_dir=dhcp
        modes=(lease-acquire lifecycle renewal reconfigure nak restart carrier tcp)
        tap_modes=("${modes[@]}")
        compare_transcripts=1
        ;;
    *) printf 'qualification: unknown cohort: %s\n' "$cohort" >&2; exit 2 ;;
esac

if [[ -n "$selected" ]]; then
    known=0
    for name in "${witnesses[@]##*/}" "${modes[@]}"; do [[ "$name" != "$selected" ]] || known=1; done
    (( known )) || { printf 'qualification: unknown %s case: %s\n' "$cohort" "$selected" >&2; exit 2; }
fi
case "$backend" in linux) backends=(linux) ;; asterinas) backends=(asterinas) ;; both) backends=(linux asterinas) ;; *) exit 2 ;; esac

mkdir -p "$repo_root/.work/tmp"
export TMPDIR="$repo_root/.work/tmp"
work="$(mktemp -d "$TMPDIR/$cohort.XXXXXXXX")"
failed=0
passed_cases=0
job_pids=()

cancel_jobs() {
    local pid
    for pid in "${job_pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    for pid in "${job_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    job_pids=()
}
trap 'cancel_jobs; rm -rf -- "$work"; exit 143' TERM
trap 'cancel_jobs; rm -rf -- "$work"; exit 130' INT

run_backends() {
    local label="$1"; shift
    local side
    job_pids=()
    for side in "${backends[@]}"; do
        mkdir -p "$work/$label-$side"
        "$@" "$side" "$work/$label-$side" > "$work/$label-$side.log" 2>&1 &
        job_pids+=("$!")
    done
    local index=0 ok=1
    for side in "${backends[@]}"; do
        if ! wait "${job_pids[$index]}"; then
            failed=1
            ok=0
            printf 'qualification: %s failed on %s\n' "$label" "$side" >&2
            tail -n 20 "$work/$label-$side.log" >&2
        fi
        index=$((index + 1))
    done
    job_pids=()
    return $(( 1 - ok ))
}

witness() { exec bash "$repo_root/infra/asterinas/run-witness.sh" "$2" "$regression/$1.c" "$3"; }
guest_mode() {
    local network=""
    local tapped
    for tapped in "${tap_modes[@]}"; do [[ "$tapped" != "$1" ]] || network=tap; done
    LAPUTA_GUEST_NETWORK="$network" exec bash "$repo_root/infra/asterinas/run-guest-case.sh" "$2" "$repo_root/guest/asterinas/$case_dir" "$1" "$3"
}

transcript() {
    sed 's/\x1b\[[0-9;]*m//g' "$1/console.log" | tr -d '\r' | rg '^NET_' | rg -v '^NET_[A-Za-z0-9_]*_(ADDR|ROUTE|RULE) (\S+ )?inet6 ' || true
}

for path in "${witnesses[@]}"; do
    name="${path##*/}"
    [[ -z "$selected" || "$selected" == "$name" ]] || continue
    if run_backends "witness-$name" witness "$path"; then
        passed_cases=$((passed_cases + 1))
        printf 'qualification: %s witness %s passed for %s\n' "$cohort" "$name" "$backend"
    fi
done

for mode in "${modes[@]}"; do
    [[ -z "$selected" || "$selected" == "$mode" ]] || continue
    run_backends "mode-$mode" guest_mode "$mode" || continue
    if (( compare_transcripts )) && [[ "$backend" == both ]]; then
        transcript "$work/mode-$mode-linux" > "$work/mode-$mode-linux.transcript"
        transcript "$work/mode-$mode-asterinas" > "$work/mode-$mode-asterinas.transcript"
        [[ -s "$work/mode-$mode-linux.transcript" ]] || { printf 'qualification: %s produced no transcript\n' "$mode" >&2; failed=1; continue; }
        if ! diff -u "$work/mode-$mode-linux.transcript" "$work/mode-$mode-asterinas.transcript" >&2; then
            printf 'qualification: %s differs between Linux and Asterinas\n' "$mode" >&2
            failed=1
            continue
        fi
    fi
    passed_cases=$((passed_cases + 1))
    printf 'qualification: %s case %s passed for %s\n' "$cohort" "$mode" "$backend"
done

if (( failed )); then
    printf 'qualification: %s failed; results kept in %s\n' "$cohort" "$work" >&2
    exit 1
fi
(( passed_cases > 0 )) || { printf 'qualification: %s ran no case\n' "$cohort" >&2; exit 1; }
rm -rf -- "$work"
printf 'qualification: %s passed %s cases for %s\n' "$cohort" "$passed_cases" "$backend"
