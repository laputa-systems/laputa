#!/usr/bin/env bash
set -euo pipefail
if test "$(uname -s)" != Linux || test "$(uname -m)" != x86_64; then
  printf 'self-hosting qualification requires Linux x86_64\n' >&2
  exit 2
fi
repository=$(realpath "${1:?usage: self_hosting_successor.sh REPOSITORY INPUT_ROOT PREVIOUS_OUTPUT TOOLS_IMAGE XSH}")
input_root=$(realpath "${2:?input root}")
previous_output=$(realpath "${3:?previous output root}")
tools_image=$(docker image inspect --format '{{.Id}}' "${4:?saved tools image}")
xsh=$(realpath "${5:?frozen host xsh}")
case "$input_root" in "$repository"/.work/*) ;; *) exit 2 ;; esac
case "$previous_output" in "$repository"/.work/*) ;; *) exit 2 ;; esac
source "$repository/tests/integration/self_hosting_lock.sh"
self_hosting_lock "$input_root.lock" LAPUTA_SELF_HOSTING_INPUT_LOCK_FD
self_hosting_lock "${previous_output}.lock" LAPUTA_SELF_HOSTING_OUTPUT_LOCK_FD
self_hosting_disk_lock "$repository" "$previous_output"
export TMPDIR="$repository/.work/tmp"
mkdir -p "$TMPDIR"
work=$(mktemp -d "$TMPDIR/self-hosting-successor.XXXXXXXX")
build_uid=$(id -u)
build_gid=$(id -g)
docker run --rm --user 0:0 --network none --memory 1g \
  --mount "type=bind,src=$previous_output,dst=/input,readonly" \
  --mount "type=bind,src=$work,dst=/extract" \
  "$tools_image" /usr/sbin/debugfs -R 'rdump /successor /extract' /input/output.ext4
docker run --rm --user 0:0 --network none --memory 128m \
  --mount "type=bind,src=$work,dst=/extract" \
  "$tools_image" /bin/chown -R "$build_uid:$build_gid" /extract
successor_output="$work/successor"
test -f "$successor_output/current/generation.json"
cp "$successor_output/current/generation.json" "$input_root/inputs/generation-B.json"
XSH_MODULE_PATH="$repository" "$xsh" "$repository/pm.xsh" -- store extract \
  "$successor_output/current/build-plan.json" --store "$input_root/inputs/artifacts-A" \
  --package linux --path boot/vmlinuz --output "$successor_output/selected-kernel"
previous_generation=$(jaq -r '.generation_sha256' "$previous_output/current/generation.json")
successor_generation=$(jaq -r '.generation_sha256' "$successor_output/current/generation.json")
XSH_MODULE_PATH="$repository" "$xsh" "$repository/tests/system/fixtures/self-hosting-negative.xsh" -- \
  "$previous_output/current" "$successor_output/current" "$previous_generation" "$successor_generation" \
  "$successor_output/selected-kernel" "$tools_image"
python3 - "$previous_output/output.ext4" "$successor_output/output.ext4" <<'PY'
import os, sys
os.symlink(sys.argv[1], sys.argv[2])
PY
"$repository/tests/integration/self_hosting.sh" boot-successor \
  "$repository" "$input_root" "$successor_output" "$tools_image" "$xsh"
"$repository/tests/integration/self_hosting.sh" preserve-previous \
  "$repository" "$input_root" "$previous_output" "$tools_image" "$xsh"
printf 'successor output: %s\n' "$successor_output"
