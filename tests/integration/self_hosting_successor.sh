#!/usr/bin/env bash
set -euo pipefail
if test "$(uname -s)" != Linux || test "$(uname -m)" != x86_64; then
  printf 'self-hosting qualification requires Linux x86_64\n' >&2
  exit 2
fi
repository=$(realpath "${1:?usage: self_hosting_successor.sh REPOSITORY INPUT_ROOT PREVIOUS_OUTPUT TOOLS_IMAGE XSH [replacement|installed-tools]}")
input_root=$(realpath "${2:?input root}")
previous_output=$(realpath "${3:?previous output root}")
tools_image=$(docker image inspect --format '{{.Id}}' "${4:?saved tools image}")
xsh=$(realpath "${5:?frozen host xsh}")
checksum=("$xsh" "$input_root/inputs/seed-A/core/sha256sum" --)
case "${6:-replacement}" in
  replacement) successor_phase=boot-successor; previous_phase=preserve-previous ;;
  installed-tools) successor_phase=boot-package-successor; previous_phase=preserve-package-previous ;;
  *) exit 2 ;;
esac
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
runtime_input="$work/runtime-input"
mkdir -p "$runtime_input/inputs"
for name in laputa seed-A generation-A.json generation-B.json; do
  cp -R "$input_root/inputs/$name" "$runtime_input/inputs/$name"
done
if test "$successor_phase" = boot-package-successor; then
  cp "$input_root/inputs/previous-os-release" "$runtime_input/inputs/previous-os-release"
  cp "$input_root/inputs/development-os-release" "$runtime_input/inputs/development-os-release"
fi
XSH_MODULE_PATH="$repository" "$xsh" "$repository/pm.xsh" -- store extract \
  "$successor_output/current/build-plan.json" --store "$input_root/inputs/artifacts-A" \
  --package linux --path boot/vmlinuz --output "$successor_output/selected-kernel"
previous_generation=$(jaq -r '.generation_sha256' "$previous_output/current/generation.json")
successor_generation=$(jaq -r '.generation_sha256' "$successor_output/current/generation.json")
XSH_MODULE_PATH="$repository" "$xsh" "$repository/tests/system/fixtures/self-hosting-negative.xsh" -- \
  "$previous_output/current" "$successor_output/current" "$previous_generation" "$successor_generation" \
  "$successor_output/selected-kernel" "$tools_image"
activate() {
  XSH_MODULE_PATH="$repository" "$xsh" "$repository/seed/self_hosting_activation.xsh" -- \
    "$1" "$previous_output" "$2" "$successor_output/selected-kernel" "$tools_image"
}
if test ! -f "$previous_output/generations/activation.json"; then
  activate install "$previous_output/current"
fi
test "$(jaq -r '.current.id' "$previous_output/generations/activation.json")" = "$previous_generation"
test "$(jaq -r '.pending' "$previous_output/generations/activation.json")" = null
activate stage "$successor_output/current"
"${checksum[@]}" "$previous_output/output.ext4" "$previous_output/current/"{vmlinuz,rootfs.ext4,disk.img,generation.json} > "$work/preserved.sha256"
for attempt in 1 2; do
  if "$repository/tests/integration/self_hosting.sh" fail-successor \
    "$repository" "$runtime_input" "$previous_output" "$tools_image" "$xsh"; then
    printf 'failed candidate unexpectedly passed\n' >&2
    exit 1
  fi
  cp "$previous_output/console.log" "$work/failure-$attempt-console.log"
  cp "$previous_output/generations/activation.json" "$work/failure-$attempt-activation.json"
  case "$(< "$previous_output/console.log")" in
    *'deliberate self-hosting candidate health failure'*) ;;
    *) printf 'candidate failed for an unexpected reason\n' >&2; exit 1 ;;
  esac
  test "$(jaq -r '.boot_attempts' "$previous_output/generations/activation.json")" = "$attempt"
  test "$(jaq -r '.last_operation' "$previous_output/generations/activation.json")" != confirmed
done
test "$(jaq -r '.current.id' "$previous_output/generations/activation.json")" = "$previous_generation"
test "$(jaq -r '.pending' "$previous_output/generations/activation.json")" = null
test "$(jaq -r '.last_operation' "$previous_output/generations/activation.json")" = fell-back
"${checksum[@]}" -c "$work/preserved.sha256"
"$repository/tests/integration/self_hosting.sh" "$previous_phase" \
  "$repository" "$runtime_input" "$previous_output" "$tools_image" "$xsh"
cp "$previous_output/console.log" "$work/fallback-console.log"
activate restage "$successor_output/current"
"$repository/tests/integration/self_hosting.sh" "$successor_phase" \
  "$repository" "$runtime_input" "$previous_output" "$tools_image" "$xsh"
cp "$previous_output/console.log" "$work/successor-console.log"
activate confirm "$successor_output/current"
cp "$previous_output/generations/activation.json" "$work/confirmed-activation.json"
test "$(jaq -r '.current.id' "$previous_output/generations/activation.json")" = "$successor_generation"
test "$(jaq -r '.fallback.id' "$previous_output/generations/activation.json")" = "$previous_generation"
test "$(jaq -r '.last_operation' "$previous_output/generations/activation.json")" = confirmed
activate restage "$previous_output/current"
"$repository/tests/integration/self_hosting.sh" "$previous_phase" \
  "$repository" "$runtime_input" "$previous_output" "$tools_image" "$xsh"
cp "$previous_output/console.log" "$work/rollback-console.log"
activate confirm "$previous_output/current"
"${checksum[@]}" -c "$work/preserved.sha256"
printf 'successor output: %s\n' "$successor_output"
