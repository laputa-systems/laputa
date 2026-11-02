#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/run-cancellable.sh"
export ASTERINAS_EXTRA_PACKAGES="${ASTERINAS_EXTRA_PACKAGES-ntpd-rs}"
cohort="${1:-}"
case "$cohort" in baseline|device|clock-abi|clock|network-state|network|recovery|resources|all) ;; *) printf 'qualification: unsupported cohort\n' >&2; exit 2 ;; esac
shift
backend=""
case_name=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend) [[ $# -ge 2 && -z "$backend" ]] || exit 2; backend="$2"; shift 2 ;;
        --case) [[ $# -ge 2 && -z "$case_name" ]] || exit 2; case_name="$2"; shift 2 ;;
        *) printf 'qualification: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
case "$backend" in linux|asterinas|both) ;; *) printf 'qualification: select --backend linux, asterinas, or both\n' >&2; exit 2 ;; esac
self="$repo_root/infra/asterinas/qualify.sh"
cohort_runner="$repo_root/infra/asterinas/qualify-cohort.sh"

case "$cohort" in
    device)
        case "$case_name" in
            '') run_cancellable "" bash "$self" baseline --backend "$backend" --case boot
                run_cancellable "" bash "$cohort_runner" device "$backend" '' ;;
            boot) run_cancellable "" bash "$self" baseline --backend "$backend" --case boot ;;
            *) run_cancellable "" bash "$cohort_runner" device "$backend" "$case_name" ;;
        esac
        exit 0
        ;;
    clock-abi|clock|network-state|network)
        run_cancellable "" bash "$cohort_runner" "$cohort" "$backend" "$case_name"
        exit $?
        ;;
    resources)
        run_cancellable "" bash "$repo_root/infra/asterinas/resources.sh" "$backend" "$case_name"
        exit $?
        ;;
    recovery|all)
        [[ -z "$case_name" ]] || { printf 'qualification: %s takes no --case\n' "$cohort" >&2; exit 2; }
        repeats="${LAPUTA_RECOVERY_REPEATS:-10}"
        [[ "$repeats" =~ ^[1-9][0-9]*$ ]] || { printf 'qualification: invalid LAPUTA_RECOVERY_REPEATS: %s\n' "$repeats" >&2; exit 2; }
        failures=()
        if [[ "$cohort" == all ]]; then
            for step in baseline device clock-abi clock network-state network; do
                run_cancellable "" bash "$self" "$step" --backend "$backend" || failures+=("$step")
            done
        fi
        for ((round = 1; round <= repeats; round++)); do
            printf 'qualification: recovery round %s of %s\n' "$round" "$repeats"
            run_cancellable "" bash "$self" baseline --backend "$backend" --case boot || failures+=("recovery-$round-boot")
            run_cancellable "" bash "$cohort_runner" network "$backend" restart || failures+=("recovery-$round-restart")
            run_cancellable "" bash "$cohort_runner" network "$backend" carrier || failures+=("recovery-$round-carrier")
        done
        if (( ${#failures[@]} )); then
            printf 'qualification: %s failed: %s\n' "$cohort" "${failures[*]}" >&2
            exit 1
        fi
        printf 'qualification: %s passed for %s\n' "$cohort" "$backend"
        exit 0
        ;;
esac
case "$case_name" in '') cases=(boot numeric) ;; boot|numeric) cases=("$case_name") ;; *) printf 'qualification: unknown baseline case: %s\n' "$case_name" >&2; exit 2 ;; esac

output="$repo_root/.out/asterinas-firecracker"
mkdir -p "$repo_root/.work/tmp" "$output"
export TMPDIR="$repo_root/.work/tmp"
work="$(mktemp -d "$repo_root/.work/tmp/asterinas-qualification.XXXXXXXX")"
trap 'cancellable_stop; rm -rf -- "$work"' EXIT
linux_package="${LAPUTA_LINUX_KERNEL_PACKAGE:-$output/linux-package.tar.gz}"
if [[ "$backend" != asterinas ]]; then
    run_cancellable "" bash "$repo_root/infra/asterinas/linux-reference.sh" "$linux_package" "$work"
fi

for case_name in "${cases[@]}"; do
    selection=""
    [[ "$case_name" != numeric ]] || selection=tests/xsh/stdlib/numeric.xsh
    if [[ "$backend" == linux ]]; then
        XSH_TEST="$selection" run_cancellable "" make -C "$repo_root" asterinas-build
    else
        XSH_TEST="$selection" run_cancellable "" make -C "$repo_root" asterinas-test
        cp "$output/test-console.log" "$output/qualification-asterinas-$case_name.log"
        if [[ -n "$selection" ]]; then
            rg -q '^running [1-9][0-9]* tests\r?$' "$output/test-console.log" || { printf 'qualification: empty XSH selection\n' >&2; exit 1; }
            rg '^tests/xsh/stdlib/numeric\.xsh::' "$output/test-console.log" | sed 's/ \.\.\. .*//' > "$work/asterinas-ids"
        fi
    fi
    if [[ "$backend" != asterinas ]]; then
        bundle="$(realpath "$output/current")"
        (cd "$bundle" && sha256sum -c SHA256SUMS)
        cp "$bundle/laputa-root.ext2" "$work/linux-root.ext2"
        chmod u+w "$work/linux-root.ext2"
        cmp "$bundle/laputa-root.ext2" "$work/linux-root.ext2"
        if [[ -n "$selection" ]]; then
            bash "$repo_root/infra/asterinas/inject-guest-file.sh" \
                "$work/linux-root.ext2" "$output/xsh-test.selection" usr/lib/asterinas/xsh-test.selection \
                "$(docker image inspect --format '{{.Id}}' "asterinas/dev:$(cat "$repo_root/asterinas/DOCKER_IMAGE_VERSION")")"
        fi
        timeout_seconds=60
        [[ -z "$selection" ]] || timeout_seconds=300
        XSH_MODULE_PATH="$repo_root" run_cancellable "" "$repo_root/.out/host/x86_64/xsh" "$repo_root/infra/asterinas/run-linux.xsh" -- \
            "$work/linux-kernel" "$work/linux-initramfs.cpio.gz" "$work/linux-root.ext2" \
            "$output/qualification-linux-$case_name.log" "$output/qualification-linux-$case_name-qemu.log" \
            "$selection" "$timeout_seconds" "$([[ -z "$selection" ]] && echo 1024 || echo 4096)"
        if [[ -n "$selection" && "$backend" == both ]]; then
            rg '^tests/xsh/stdlib/numeric\.xsh::' "$output/qualification-linux-$case_name.log" | sed 's/ \.\.\. .*//' > "$work/linux-ids"
            cmp "$work/asterinas-ids" "$work/linux-ids" || { printf 'qualification: selected test identities differ\n' >&2; exit 1; }
        fi
    fi
    printf 'qualification: baseline %s passed for %s\n' "$case_name" "$backend"
done
