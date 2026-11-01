#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# == 2 ]] || { printf 'usage: linux-reference.sh LINUX_PACKAGE OUTPUT_DIR\n' >&2; exit 2; }
linux_package="$1"
work="$2"
[[ -f "$linux_package" ]] || { printf 'qualification: Laputa Linux package is missing: %s\n' "$linux_package" >&2; exit 1; }
for tool in cc cpio gzip tar; do command -v "$tool" >/dev/null || { printf 'qualification: missing %s\n' "$tool" >&2; exit 1; }; done
mkdir -p "$work"
tar -xOzf "$linux_package" boot/vmlinuz > "$work/linux-kernel"
[[ -s "$work/linux-kernel" ]] || { printf 'qualification: Linux package has no kernel\n' >&2; exit 1; }
mkdir -p "$work/initramfs"/{dev,newroot,proc,sys}
cc -DLAPUTA_LINUX_REFERENCE -ffreestanding -fno-builtin -fno-pie -fno-stack-protector -mno-sse -mno-mmx -nostdlib -static -no-pie -O2 -Wl,-e,_start -Wl,--build-id=none "$repo_root/guest/asterinas/initramfs/init.c" -o "$work/initramfs/init"
(cd "$work/initramfs" && printf '%s\n' . dev newroot proc sys init | cpio -o -H newc 2>/dev/null | gzip -n > "$work/linux-initramfs.cpio.gz")
