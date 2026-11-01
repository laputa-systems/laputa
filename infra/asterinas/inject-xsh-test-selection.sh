#!/usr/bin/env bash
set -euo pipefail

[[ $# == 3 ]] || {
    printf 'usage: inject-xsh-test-selection.sh ROOT_IMAGE SELECTION_FILE TOOLS_IMAGE\n' >&2
    exit 2
}
root_image="$(realpath "$1")"
selection_file="$(realpath "$2")"
tools_image="$3"
guest_directory=usr/lib/asterinas
guest_name=xsh-test.selection

[[ -f "$root_image" && -w "$root_image" ]] || { printf 'inject-xsh-test-selection: root image is not writable: %s\n' "$root_image" >&2; exit 1; }
[[ -s "$selection_file" ]] || { printf 'inject-xsh-test-selection: selection file is empty: %s\n' "$selection_file" >&2; exit 1; }

commands="$(mktemp -d)"
trap 'rm -rf -- "$commands"' EXIT
printf 'cd %s\nwrite /selection %s\n' "$guest_directory" "$guest_name" > "$commands/write"

debugfs() {
    docker run --rm --pull never --platform linux/amd64 --network none --entrypoint /sbin/debugfs \
        --mount "type=bind,src=$(dirname "$root_image"),dst=/image" \
        --mount "type=bind,src=$selection_file,dst=/selection,readonly" \
        --mount "type=bind,src=$commands,dst=/commands,readonly" \
        "$tools_image" "$@" "/image/$(basename "$root_image")"
}

debugfs -w -f /commands/write > /dev/null
[[ "$(debugfs -R "cat $guest_directory/$guest_name" 2>/dev/null)" == "$(cat "$selection_file")" ]] || {
    printf 'inject-xsh-test-selection: selection did not reach the root image\n' >&2
    exit 1
}
