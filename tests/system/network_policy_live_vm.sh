#!/usr/bin/env bash
set -euo pipefail
repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
seed=$(realpath "${1:?usage: network_policy_live_vm.sh CLEAN_SEED CANONICAL_ROOT_BUNDLE}")
original=$(realpath "${2:?canonical self-hosting root bundle}")
git -C "$repository" check-ignore --quiet .work/tmp
jaq -e '.xsh_dirty == false and .arch == "x86_64"' "$seed/manifest.json" >/dev/null
for product in xsh xsht core.tar.xz; do
  expected=$(jaq -r --arg product "$product" '.files[$product]' "$seed/manifest.json")
  test "$(sha256sum "$seed/$product" | cut -d ' ' -f 1)" = "$expected"
done
test "$(jaq -r '.generation_sha256' "$original/generation.json")" = 906009468ffe783b2078aacfe5f1002e7294a15ac57712e50a2d09766229a8a5
mkdir -p "$repository/.work/tmp"
work=$(mktemp -d "$repository/.work/tmp/network-live.XXXXXXXX")
export TMPDIR="$work"
child=""
cleanup() {
  result=$?
  trap - EXIT
  if test -n "$child"; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" || true
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
printf 'live-network evidence: %s\n' "$work"
mkdir -p "$work/input/inputs/laputa/packages" "$work/input/tools/bin" "$work/vm/current"
cp -a "$repository/pm" "$repository/pm.xsh" "$repository/tests" "$repository/xsht-config.ini" "$work/input/inputs/laputa/"
cp -a "$repository/packages/laputa-net" "$work/input/inputs/laputa/packages/"
cp "$repository/tests/system/fixtures/network-policy-live-entry.xsh" "$work/input/inputs/entry.xsh"
cp "$seed/xsh" "$seed/xsht" "$work/input/tools/bin/"
cp "$seed/manifest.json" "$work/input/tools/seed-manifest.json"
cp "$seed/core.tar.xz" "$work/input/tools/"
jaq -e '.xsh_dirty == false and .arch == "x86_64"' "$work/input/tools/seed-manifest.json" >/dev/null
for product in xsh xsht core.tar.xz; do
  expected=$(jaq -r --arg product "$product" '.files[$product]' "$work/input/tools/seed-manifest.json")
  staged="$work/input/tools/bin/$product"
  if test "$product" = core.tar.xz; then staged="$work/input/tools/$product"; fi
  test "$(sha256sum "$staged" | cut -d ' ' -f 1)" = "$expected"
done
tar -xJf "$work/input/tools/core.tar.xz" -C "$work/input/tools"
sha256sum "$seed/manifest.json" "$seed/xsh" "$seed/xsht" "$seed/core.tar.xz" > "$work/seed-input-hashes.sha256"
sha256sum "$repository/packages/laputa-net/network_kernel.xsh" "$repository/packages/laputa-net/network_plan.xsh" "$repository/tests/system/fixtures/network-policy-applier.xsh" "$repository/tests/system/fixtures/network-policy-writer.xsh" "$repository/tests/system/fixtures/network-policy-live-entry.xsh" "$repository/tests/system/fixtures/network-policy-live-verify.xsh" "$repository/tests/system/fixtures/network-policy-live-guest.xsh" "$repository/tests/system/fixtures/network-policy-live-host.xsh" "$repository/tests/system/network_policy_applier.xsh" "$repository/tests/system/network_policy_live_vm.sh" > "$work/source-input-hashes.sha256"
git -C "$repository" rev-parse HEAD > "$work/source-revision.txt"
rg --files -uuu -0 "$work/input" | sort -z | xargs -0 sha256sum > "$work/input-files.sha256"
sha256sum "$original/disk.img" "$original/rootfs.ext4" "$original/vmlinuz" "$original/generation.json" > "$work/original-root-before.sha256"
cp --reflink=auto "$original/disk.img" "$original/rootfs.ext4" "$original/vmlinuz" "$original/generation.json" "$work/vm/current/"
truncate -s 256M "$work/vm/inputs.ext4"
/sbin/mkfs.ext4 -q -F -d "$work/input" "$work/vm/inputs.ext4"
truncate -s 128M "$work/vm/output.ext4"
/sbin/mkfs.ext4 -q -F "$work/vm/output.ext4"
status=0
XSH_MODULE_PATH="$repository" "$seed/xsh" "$repository/tests/system/fixtures/network-policy-live-host.xsh" -- "$repository" "$work/vm" > "$work/host.log" 2>&1 &
child=$!
wait "$child" || status=$?
child=""
sha256sum -c "$work/original-root-before.sha256" > "$work/original-root-after.log" || status=1
cat "$work/host.log"
exit "$status"
