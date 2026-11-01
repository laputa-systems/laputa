#!/usr/bin/env bash
set -euo pipefail

[[ $# == 4 ]] || {
    printf 'usage: inject-guest-file.sh ROOT_IMAGE HOST_FILE GUEST_PATH TOOLS_IMAGE\n' >&2
    exit 2
}
root_image="$(realpath "$1")"
host_file="$(realpath "$2")"
guest_path="${3#/}"
tools_image="$4"
guest_directory="$(dirname "$guest_path")"
guest_name="$(basename "$guest_path")"

[[ -f "$root_image" && -w "$root_image" ]] || { printf 'inject-guest-file: root image is not writable: %s\n' "$root_image" >&2; exit 1; }
[[ -s "$host_file" ]] || { printf 'inject-guest-file: file is empty: %s\n' "$host_file" >&2; exit 1; }

commands="$(mktemp -d)"
trap 'rm -rf -- "$commands"' EXIT
printf 'mkdir %s\ncd %s\nwrite /injected %s\n' "$guest_directory" "$guest_directory" "$guest_name" > "$commands/write"

debugfs() {
    docker run --rm --pull never --platform linux/amd64 --network none --entrypoint /sbin/debugfs \
        --mount "type=bind,src=$(dirname "$root_image"),dst=/image" \
        --mount "type=bind,src=$host_file,dst=/injected,readonly" \
        --mount "type=bind,src=$commands,dst=/commands,readonly" \
        "$tools_image" "$@" "/image/$(basename "$root_image")"
}

debugfs -w -f /commands/write > /dev/null
debugfs -R "cat $guest_path" 2>/dev/null | cmp -s - "$host_file" || {
    printf 'inject-guest-file: %s did not reach the root image\n' "$guest_path" >&2
    exit 1
}
