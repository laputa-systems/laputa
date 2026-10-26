#!/usr/bin/env bash
set -euo pipefail
repository=$(realpath "${1:?usage: self_hosting_lock_test.sh REPOSITORY}")
source "$repository/tests/integration/self_hosting_lock.sh"
mkdir -p "$repository/.work/tmp"
work=$(mktemp -d "$repository/.work/tmp/self-hosting-lock.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/previous" "$work/successor"
touch "$work/previous/output.ext4"
ln -s "$work/previous/output.ext4" "$work/successor/output.ext4"
self_hosting_disk_lock "$repository" "$work/previous"
bash -c '
  set -euo pipefail
  source "$1/tests/integration/self_hosting_lock.sh"
  self_hosting_disk_lock "$1" "$2"
  touch "$3"
' _ "$repository" "$work/successor" "$work/inherited"
test -f "$work/inherited"
if env -u LAPUTA_SELF_HOSTING_DISK_LOCK_FD bash -c '
  set -euo pipefail
  source "$1/tests/integration/self_hosting_lock.sh"
  self_hosting_disk_lock "$1" "$2"
  touch "$3"
' _ "$repository" "$work/successor" "$work/contender" 2>"$work/contender-error"; then
  printf 'a competing successor phase acquired the previous disk\n' >&2
  exit 1
fi
test ! -e "$work/contender"
rg -q 'self-hosting path is already in use:' "$work/contender-error"
mkdir "$work/hardlink"
ln "$work/previous/output.ext4" "$work/hardlink/output.ext4"
if (self_hosting_disk_lock "$repository" "$work/hardlink") 2>"$work/hardlink-error"; then
  printf 'a hardlink alias acquired the shared disk\n' >&2
  exit 1
fi
rg -q 'output disk must have exactly one hard link' "$work/hardlink-error"
printf 'self-hosting disk lock: inherited owner accepted; competing aliases rejected\n'
