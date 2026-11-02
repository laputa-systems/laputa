#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/run-cancellable.sh"
[[ $# -ge 1 && $# -le 2 ]] || { printf 'usage: resources.sh linux|asterinas|both [boot|numeric]\n' >&2; exit 2; }
case "$1" in linux) backends=(linux) ;; asterinas) backends=(asterinas) ;; both) backends=(linux asterinas) ;; *) printf 'resources: unsupported backend: %s\n' "$1" >&2; exit 2 ;; esac
case "${2:-}" in '') cases=(boot numeric) ;; boot|numeric) cases=("$2") ;; *) printf 'resources: unknown case: %s\n' "$2" >&2; exit 2 ;; esac
for tool in awk getconf jaq perf-gate-ready ps stat tar; do
    command -v "$tool" > /dev/null || { printf 'resources: missing host command: %s\n' "$tool" >&2; exit 1; }
done

output="$repo_root/.out/asterinas-firecracker"
qualify="$repo_root/infra/asterinas/qualify.sh"
linux_package="${LAPUTA_LINUX_KERNEL_PACKAGE:-$output/linux-package.tar.gz}"
ticks_per_second="$(getconf CLK_TCK)"
mkdir -p "$repo_root/.work/tmp"
export TMPDIR="$repo_root/.work/tmp"
work="$(mktemp -d "$repo_root/.work/tmp/asterinas-resources.XXXXXXXX")"
sampler=""
stop_sampler() {
    [[ -z "$sampler" ]] || kill "$sampler" 2> /dev/null || true
    [[ -z "$sampler" ]] || wait "$sampler" 2> /dev/null || true
    sampler=""
}
trap 'stop_sampler; cancellable_stop; rm -rf -- "$work"' EXIT

vmm_descendants() {
    ps -e -o pid=,ppid=,comm= | awk -v root="$1" '
        { parent[$1] = $2; name[$1] = $3 }
        END {
            for (pid in parent) {
                ancestor = pid
                while ((ancestor in parent) && ancestor != root) ancestor = parent[ancestor]
                if (ancestor == root && (name[pid] == "firecracker" || name[pid] ~ /^qemu-system/)) print pid
            }
        }'
}

configured_memory_mib() {
    local pid="$1" arguments config
    arguments="$(tr '\0' '\n' < "/proc/$pid/cmdline")"
    if [[ "$(< "/proc/$pid/comm")" == firecracker ]]; then
        config="$(awk 'previous == "--config-file" { print; exit } { previous = $0 }' <<< "$arguments")"
        jaq '.["machine-config"].mem_size_mib' "$config"
    else
        awk 'previous == "-m" { print; exit } { previous = $0 }' <<< "$arguments"
    fi
}

sample_vmm() {
    local root="$1" record="$2" pid peak user system memory="" vmm=""
    local best_peak=0 best_user=0 best_system=0
    while :; do
        for pid in $(vmm_descendants "$root"); do
            peak="$(awk '$1 == "VmHWM:" { print $2 }' "/proc/$pid/status" 2> /dev/null)" || continue
            [[ -n "$peak" ]] || continue
            read -r user system < <(awk '{ sub(/^.*\) /, ""); print $12, $13 }' "/proc/$pid/stat" 2> /dev/null) || continue
            [[ -n "$memory" ]] || memory="$(configured_memory_mib "$pid" 2> /dev/null)" || continue
            vmm="$(< "/proc/$pid/comm")"
            (( peak <= best_peak )) || best_peak="$peak"
            (( user <= best_user )) || best_user="$user"
            (( system <= best_system )) || best_system="$system"
            printf '%s %s %s %s %s\n' "$vmm" "$memory" "$best_peak" "$best_user" "$best_system" > "$record.tmp"
            mv -f "$record.tmp" "$record"
        done
        sleep 0.05
    done
}

file_bytes() { stat -L -c %s "$1"; }
allocated_bytes() { echo $(( $(stat -L -c %b "$1") * $(stat -L -c %B "$1") )); }

deferred=()
measured=0
for backend in "${backends[@]}"; do
    linux_kernel_bytes=""
    linux_initramfs_bytes=""
    if [[ "$backend" == linux ]]; then
        bash "$repo_root/infra/asterinas/linux-reference.sh" "$linux_package" "$work/linux"
        linux_kernel_bytes="$(file_bytes "$work/linux/linux-kernel")"
        linux_initramfs_bytes="$(file_bytes "$work/linux/linux-initramfs.cpio.gz")"
    fi
    for case_name in "${cases[@]}"; do
        record="$work/$backend-$case_name.record"
        gate_before=0
        perf-gate-ready || gate_before=$?
        sample_vmm "$$" "$record" &
        sampler=$!
        run_cancellable "" bash "$qualify" baseline --backend "$backend" --case "$case_name"
        stop_sampler
        gate_after=0
        perf-gate-ready -1 || gate_after=$?
        [[ -s "$record" ]] || { printf 'resources: no VMM process was observed for %s %s\n' "$backend" "$case_name" >&2; exit 1; }
        read -r vmm memory peak user system < "$record"
        bundle="$(realpath "$output/current")"
        if [[ "$backend" == linux ]]; then
            kernel_bytes="$linux_kernel_bytes"
            initramfs_bytes="$linux_initramfs_bytes"
        else
            kernel_bytes="$(file_bytes "$bundle/kernel.elf")"
            initramfs_bytes="$(file_bytes "$bundle/laputa-initramfs.cpio.gz")"
        fi
        line="resources: backend=$backend case=$case_name vmm=$vmm kernel_bytes=$kernel_bytes initramfs_bytes=$initramfs_bytes root_bytes=$(file_bytes "$bundle/laputa-root.ext2") root_allocated_bytes=$(allocated_bytes "$bundle/laputa-root.ext2") memory_mib=$memory peak_rss_kib=$peak"
        if (( gate_before == 0 && gate_after == 0 )); then
            line+=" cpu_user_ms=$(( user * 1000 / ticks_per_second )) cpu_sys_ms=$(( system * 1000 / ticks_per_second ))"
        else
            line+=" cpu=deferred"
            deferred+=("$backend/$case_name")
        fi
        printf '%s\n' "$line"
        measured=$(( measured + 1 ))
    done
done
(( measured > 0 )) || { printf 'resources: nothing was measured\n' >&2; exit 1; }
if (( ${#deferred[@]} )); then
    printf 'resources: perf gate deferred: host busy (%s)\n' "${deferred[*]}"
fi
printf 'resources: measured %s runs for %s\n' "$measured" "$1"
