#!/usr/bin/env bash
set -euo pipefail
if test "$(uname -s)" != Linux || test "$(uname -m)" != x86_64; then
  printf 'self-hosting qualification requires Linux x86_64\n' >&2
  exit 2
fi
phase=${1:?usage: self_hosting.sh compile|qualify|replay|compose|boot-successor|preserve-previous|network|debug REPOSITORY INPUT_ROOT OUTPUT_ROOT TOOLS_IMAGE XSH}
repository=$(realpath "${2:?repository}")
input_root=$(realpath "${3:?input root}")
output_root=$(realpath "${4:?output root}")
tools_image=$(docker image inspect --format '{{.Id}}' "${5:?saved tools image}")
xsh=$(realpath "${6:?frozen host xsh}")
case "$phase" in
  network) entry=self-hosting-network.xsh; marker=LAPUTA_SELF_HOSTING_NETWORK_REPLAYED ;;
  debug) entry=self-hosting-debug.xsh; marker=LAPUTA_SELF_HOSTING_DEBUG_DONE ;;
  compile) entry=self-hosting-compile.xsh; marker=LAPUTA_SELF_HOSTING_SOURCE_BUILD_DONE ;;
  qualify) entry=self-hosting-qualify.xsh; marker=LAPUTA_SELF_HOSTING_QUALIFIED ;;
  preserve-previous) entry=self-hosting-preserved-proof.xsh; marker=LAPUTA_SELF_HOSTING_PREVIOUS_BOOTED ;;
  boot-successor) entry=self-hosting-successor-proof.xsh; marker=LAPUTA_SELF_HOSTING_SUCCESSOR_BOOTED ;;
  replay) entry=self-hosting-replay.xsh; marker=LAPUTA_SELF_HOSTING_REPLAYED ;;
  compose) entry=self-hosting-compose.xsh; marker=LAPUTA_SELF_HOSTING_SUCCESSOR_COMPOSED ;;
  *) exit 2 ;;
esac
case "$input_root" in "$repository"/.work/*) ;; *) exit 2 ;; esac
case "$output_root" in "$repository"/.work/*) ;; *) exit 2 ;; esac
source "$repository/tests/integration/self_hosting_lock.sh"
self_hosting_lock "$input_root.lock" LAPUTA_SELF_HOSTING_INPUT_LOCK_FD
self_hosting_lock "${output_root}.lock" LAPUTA_SELF_HOSTING_OUTPUT_LOCK_FD
self_hosting_disk_lock "$repository" "$output_root"
test -f "$output_root/current/generation.json"
test -f "$input_root/inputs/xsh/Cargo.lock"
test -d "$input_root/inputs/vendor"
test -f "$input_root/inputs/laputa/guest/$entry"
mkdir -p "$repository/.work/tmp"
export TMPDIR="$repository/.work/tmp"
python3 - "$input_root/inputs/entry.xsh" "$entry" <<'PY'
import os, sys
link, entry = sys.argv[1:]
if os.path.lexists(link):
    if not os.path.islink(link):
        raise SystemExit('entry.xsh must be a symlink')
    os.unlink(link)
os.symlink('laputa/guest/' + entry, link)
PY
docker run --rm --network none --memory 1g \
  --mount "type=bind,src=$input_root,dst=/declared" \
  --mount "type=bind,src=$repository,dst=/repo,readonly" \
  --mount "type=bind,src=$xsh,dst=/bin/xsh,readonly" \
  --env XSH_MODULE_PATH=/repo "$tools_image" /bin/xsh /repo/tests/docker/fixtures/self-hosting/normalize-inputs.xsh
docker run --rm --network none --memory 1g \
  --mount "type=bind,src=$input_root,dst=/declared,readonly" \
  --mount "type=bind,src=$repository,dst=/repo,readonly" \
  --mount "type=bind,src=$xsh,dst=/bin/xsh,readonly" \
  "$tools_image" /bin/xsh /repo/tests/docker/fixtures/self-hosting/permission-probe.xsh
truncate -s 5G "$output_root/inputs.ext4"
docker run --rm --network none --memory 2g \
  --mount "type=bind,src=$input_root,dst=/inputs,readonly" \
  --mount "type=bind,src=$output_root,dst=/output" \
  "$tools_image" /sbin/mkfs.ext4 -q -F -d /inputs /output/inputs.ext4
if test "$phase" = compile; then
  test ! -e "$output_root/output.ext4"
  truncate -s 24G "$output_root/output.ext4"
  docker run --rm --network none --memory 1g \
    --mount "type=bind,src=$output_root,dst=/output" \
    "$tools_image" /sbin/mkfs.ext4 -q -F /output/output.ext4
else
  test -f "$output_root/output.ext4"
fi
if test "$phase" = boot-successor; then
  expected_generation=$(jaq -r '.generation_sha256' "$input_root/inputs/generation-B.json")
  XSH_MODULE_PATH="$repository" "$xsh" "$repository/seed/self_hosting_verify.xsh" -- \
    "$output_root/current" "$expected_generation" "$output_root/selected-kernel" "$tools_image"
fi
XSH_MODULE_PATH="$repository" "$xsh" "$repository/seed/self_hosting_boot.xsh" -- "$repository" "$output_root" "$marker"
