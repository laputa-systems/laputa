#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/run-cancellable.sh"
[[ $# == 3 ]] || { printf 'usage: qualify-cohort.sh COHORT linux|asterinas|both CASE\n' >&2; exit 2; }
cohort="$1"
backend="$2"
selected="$3"

regression="$repo_root/asterinas/test/initramfs/src/regression"
witnesses=()
case_dir=""
modes=()
tap_modes=()
failing_modes=()
compare_transcripts=0
transcript_prefix='NET_'
case "$cohort" in
    storage)
        run_cancellable "" bash "$repo_root/infra/asterinas/storage-cohort.sh" "$backend" "$selected"
        exit $?
        ;;
    device)
        witnesses=(device/block_uevent device/kmsg fs/sync/writeback)
        case_dir=device
        modes=(sysfs add nodes missing)
        failing_modes=(missing)
        compare_transcripts=1
        transcript_prefix='DEV_'
        ;;
    clock-abi)
        witnesses=(time/clock_adjust time/leap_status)
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
        modes=(loopback link netlink-link address route events packet ioctl-config)
        tap_modes=("${modes[@]}")
        compare_transcripts=1
        ;;
    network)
        witnesses=(fs/procfs/proc_boot_id network/udp_device)
        case_dir=dhcp
        modes=(lease-acquire lifecycle renewal reconfigure nak restart carrier tcp reject-routes syslog)
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

cancellable_cancelled() { rm -rf -- "$work"; }

run_backends() {
    local label="$1" argv_builder="$2"; shift 2
    local side ok=1
    for side in "${backends[@]}"; do
        mkdir -p "$work/$label-$side"
        "$argv_builder" "$side" "$work/$label-$side" "$@"
        if ! run_cancellable "" "${job_argv[@]}" > "$work/$label-$side.log" 2>&1; then
            failed=1
            ok=0
            printf 'qualification: %s failed on %s\n' "$label" "$side" >&2
            tail -n 20 "$work/$label-$side.log" >&2
        fi
    done
    return $(( 1 - ok ))
}

run_expecting_failure() {
    local label="$1" argv_builder="$2" marker="$3"; shift 3
    local side ok=1
    for side in "${backends[@]}"; do
        mkdir -p "$work/$label-$side"
        "$argv_builder" "$side" "$work/$label-$side" "$@"
        if run_cancellable "" "${job_argv[@]}" > "$work/$label-$side.log" 2>&1; then
            failed=1
            ok=0
            printf 'qualification: %s passed on %s but must fail\n' "$label" "$side" >&2
        elif ! rg -q "$marker" "$work/$label-$side/console.log"; then
            failed=1
            ok=0
            printf 'qualification: %s failed on %s without reporting %s\n' "$label" "$side" "$marker" >&2
            tail -n 20 "$work/$label-$side.log" >&2
        fi
    done
    return $(( 1 - ok ))
}

witness_argv() { job_argv=(bash "$repo_root/infra/asterinas/run-witness.sh" "$1" "$regression/$3.c" "$2"); }
guest_mode_argv() {
    local network="" tapped
    for tapped in "${tap_modes[@]}"; do [[ "$tapped" != "$3" ]] || network=tap; done
    job_argv=(env "LAPUTA_GUEST_NETWORK=$network" bash "$repo_root/infra/asterinas/run-guest-case.sh" "$1" "$repo_root/guest/asterinas/$case_dir" "$3" "$2")
}

transcript() {
    sed 's/\x1b\[[0-9;]*m//g' "$1/console.log" | tr -d '\r' | rg "^$transcript_prefix" | rg -v '^NET_[A-Za-z0-9_]*_(ADDR|ROUTE|RULE) (\S+ )?inet6 ' || true
}

for path in "${witnesses[@]}"; do
    name="${path##*/}"
    [[ -z "$selected" || "$selected" == "$name" ]] || continue
    if run_backends "witness-$name" witness_argv "$path"; then
        passed_cases=$((passed_cases + 1))
        printf 'qualification: %s witness %s passed for %s\n' "$cohort" "$name" "$backend"
    fi
done

for mode in "${modes[@]}"; do
    [[ -z "$selected" || "$selected" == "$mode" ]] || continue
    if [[ " ${failing_modes[*]} " == *" $mode "* ]]; then
        if run_expecting_failure "mode-$mode" guest_mode_argv 'DEV_EVENT_MISSING' "$mode"; then
            passed_cases=$((passed_cases + 1))
            printf 'qualification: %s case %s failed as required for %s\n' "$cohort" "$mode" "$backend"
        fi
        continue
    fi
    run_backends "mode-$mode" guest_mode_argv "$mode" || continue
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
