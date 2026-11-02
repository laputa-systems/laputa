#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 ]] || { printf 'usage: data-disk.sh IMAGE\n' >&2; exit 2; }
image="$1"
sector_count=16384

little_endian() {
    local value="$1"
    printf "\\x$(printf %02x $((value & 255)))\\x$(printf %02x $(((value >> 8) & 255)))\\x$(printf %02x $(((value >> 16) & 255)))\\x$(printf %02x $(((value >> 24) & 255)))"
}

partition_entry() {
    printf '\x00\xfe\xff\xff\x83\xfe\xff\xff'
    little_endian "$1"
    little_endian "$2"
}

rm -f -- "$image"
truncate -s $((sector_count * 512)) "$image"
{
    partition_entry 2048 4096
    partition_entry 6144 8192
    printf '\x00%.0s' {1..32}
    printf '\x55\xaa'
} | dd of="$image" bs=1 seek=446 conv=notrunc status=none
