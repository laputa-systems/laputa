#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ ${1:-} == baseline ]] || { printf 'qualification: unsupported cohort\n' >&2; exit 2; }
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
case "$case_name" in '') cases=(boot numeric) ;; boot|numeric) cases=("$case_name") ;; *) printf 'qualification: unknown baseline case: %s\n' "$case_name" >&2; exit 2 ;; esac

output="$repo_root/.out/asterinas-firecracker"
mkdir -p "$repo_root/.work/tmp" "$output"
export TMPDIR="$repo_root/.work/tmp"
work="$(mktemp -d "$repo_root/.work/tmp/asterinas-qualification.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
linux_package="${LAPUTA_LINUX_KERNEL_PACKAGE:-$output/linux-package.tar.gz}"
if [[ "$backend" != asterinas ]]; then
    [[ -f "$linux_package" ]] || { printf 'qualification: Laputa Linux package is missing: %s\n' "$linux_package" >&2; exit 1; }
    for tool in cc cpio gzip tar; do command -v "$tool" >/dev/null || { printf 'qualification: missing %s\n' "$tool" >&2; exit 1; }; done
    tar -xOzf "$linux_package" boot/vmlinuz > "$work/linux-kernel"
    [[ -s "$work/linux-kernel" ]] || { printf 'qualification: Linux package has no kernel\n' >&2; exit 1; }
    mkdir -p "$work/initramfs"/{dev,newroot,proc,sys}
    cc -DLAPUTA_LINUX_REFERENCE -ffreestanding -fno-builtin -fno-pie -fno-stack-protector -mno-sse -mno-mmx -nostdlib -static -no-pie -O2 -Wl,-e,_start -Wl,--build-id=none "$repo_root/guest/asterinas/initramfs/init.c" -o "$work/initramfs/init"
    (cd "$work/initramfs" && printf '%s\n' . dev newroot proc sys init | cpio -o -H newc 2>/dev/null | gzip -n > "$work/linux-initramfs.cpio.gz")
fi

for case_name in "${cases[@]}"; do
    selection=""
    [[ "$case_name" != numeric ]] || selection=tests/xsh/stdlib/numeric.xsh
    if [[ "$backend" == linux ]]; then
        XSH_TEST="$selection" make -C "$repo_root" asterinas-build
    else
        XSH_TEST="$selection" make -C "$repo_root" asterinas-test
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
        timeout_seconds=60
        [[ -z "$selection" ]] || timeout_seconds=300
        XSH_MODULE_PATH="$repo_root" "$repo_root/.out/host/x86_64/xsh" "$repo_root/infra/asterinas/run-linux.xsh" -- \
            "$work/linux-kernel" "$work/linux-initramfs.cpio.gz" "$work/linux-root.ext2" \
            "$output/qualification-linux-$case_name.log" "$output/qualification-linux-$case_name-qemu.log" \
            "$selection" "$timeout_seconds"
        if [[ -n "$selection" && "$backend" == both ]]; then
            rg '^tests/xsh/stdlib/numeric\.xsh::' "$output/qualification-linux-$case_name.log" | sed 's/ \.\.\. .*//' > "$work/linux-ids"
            cmp "$work/asterinas-ids" "$work/linux-ids" || { printf 'qualification: selected test identities differ\n' >&2; exit 1; }
        fi
    fi
    printf 'qualification: baseline %s passed for %s\n' "$case_name" "$backend"
done
