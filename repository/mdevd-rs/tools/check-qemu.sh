#!/bin/sh
# QEMU proof: real kernel uevents with major/minor drive node creation.
# Boots a pinned Alpine guest under KVM, runs the Rust daemon against
# /sys/block/vda, triggers `add` through the real sysfs uevent file, and
# requires matching block identity, mode 660, framed -o output, and a clean
# mdevd-coldplug sync. Prior art: tinyland harness/run-proof.sh (read-only).
# Guest mutations stay inside the guest; host sysfs and /dev are untouched.
set -eu
cd "$(dirname "$0")/.."
bash tools/build-qemu-guest.sh 2>&1 | tail -n 5
mkdir -p .work/tmp
export TMPDIR="$PWD/.work/tmp"
QMP_SOCK="$PWD/.work/qmp-mdevd.sock"
CONSOLE="$PWD/.work/qemu-mdevd-console.log"
rm -f "$QMP_SOCK" "$CONSOLE"
cleanup() {
  result=$?
  trap - EXIT
  if [ -n "${QEMU_PID:-}" ]; then
    if kill -0 "$QEMU_PID" 2>/dev/null; then
      python3 -c 'import json,socket,sys; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(10); s.connect(sys.argv[1]); f=s.makefile("rwb"); f.readline(); f.write(b"{\"execute\":\"qmp_capabilities\"}\n"); f.flush(); f.readline(); f.write(b"{\"execute\":\"quit\"}\n"); f.flush()' "$QMP_SOCK" >/dev/null 2>&1 || true
      i=0
      while kill -0 "$QEMU_PID" 2>/dev/null && [ $i -lt 5 ]; do sleep 1; i=$((i + 1)); done
      if kill -0 "$QEMU_PID" 2>/dev/null; then kill -KILL "$QEMU_PID"; fi
    fi
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  rm -f "$QMP_SOCK"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ ! -c /dev/kvm ]; then echo 'check-qemu: /dev/kvm missing (need KVM)' >&2; exit 1; fi
qemu-system-x86_64 -M q35 -m 1024 -cpu host -enable-kvm \
  -vga none -display none \
  -kernel .work/vmlinuz-virt -initrd .work/initramfs-virt \
  -append "console=ttyS0 root=/dev/vda rootfstype=ext4 rw init=/init" \
  -drive file=.work/guest.img,format=raw,if=virtio \
  -serial file:"$CONSOLE" \
  -qmp unix:"$QMP_SOCK",server=on,wait=off \
  -no-reboot > ".work/qemu-mdevd.log" 2>&1 &
QEMU_PID=$!
ok=0
i=0
while [ $i -lt 120 ]; do
  if grep -q MDEVD_QEMU_OK "$CONSOLE" 2>/dev/null; then ok=1; break; fi
  if grep -q MDEVD_QEMU_FAIL "$CONSOLE" 2>/dev/null; then break; fi
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    if grep -q MDEVD_QEMU_OK "$CONSOLE" 2>/dev/null; then ok=1; break; fi
    break
  fi
  sleep 1
  i=$((i + 1))
done
if [ $ok != 1 ]; then
  echo 'check-qemu: guest proof failed' >&2
  tail -n 40 "$CONSOLE" 2>/dev/null || true
  grep -h MDEVD_QEMU_FAIL "$CONSOLE" 2>/dev/null || true
  exit 1
fi
grep -q MDEVD_QEMU_NODE_OK "$CONSOLE" || { echo 'check-qemu: node case missing' >&2; exit 1; }
i=0
while kill -0 "$QEMU_PID" 2>/dev/null && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
if kill -0 "$QEMU_PID" 2>/dev/null; then echo 'check-qemu: QEMU did not exit' >&2; exit 1; fi
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=
echo 'check-qemu: OK (real kernel add with major/minor, coldplug sync)'
