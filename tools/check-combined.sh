#!/bin/sh
# Combined cross-project qualification: pinned mdevd + seatd + doas
# candidates plus a real libudev-zero consumer in one disposable KVM guest.
# Reuses the seatd/mdevd QEMU pattern (minirootfs base, ext4 image under
# .work/, KVM, serial markers, QMP quit). Host /dev, /sys, networking,
# console, and privilege tools are untouched. This is qualification
# evidence, not distribution integration: Laputa packages are not modified.
#
# Fails loudly when any stage is skipped: every proof below ends in a
# console marker that is grepped before reporting success.
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
SEATD=$ROOT/../seatd-rs
DOAS=$ROOT/../doas-rs
LIBUDEV_ZERO=${LIBUDEV_ZERO_SRC:-$HOME/d/libudev-zero}
PIN_LIBUDEV_ZERO=8f1d3d0624496f1c4967f18d6afaddbd552d8bce

for d in "$SEATD" "$DOAS" "$LIBUDEV_ZERO"; do
  test -d "$d" || { echo "check-combined: missing $d" >&2; exit 1; }
done
for r in "$ROOT" "$SEATD" "$DOAS"; do
  if [ -n "$(git -C "$r" status --porcelain)" ]; then
    echo "check-combined: unclean tree $r (commit before qualifying)" >&2
    exit 1
  fi
done
echo "check-combined: candidates"
echo "  mdevd $(git -C "$ROOT" rev-parse HEAD)"
echo "  seatd $(git -C "$SEATD" rev-parse HEAD)"
echo "  doas  $(git -C "$DOAS" rev-parse HEAD)"
actual=$(git -C "$LIBUDEV_ZERO" rev-parse HEAD)
if [ "$actual" != "$PIN_LIBUDEV_ZERO" ]; then
  echo "check-combined: libudev-zero $actual != $PIN_LIBUDEV_ZERO" >&2
  exit 1
fi
echo "  libudev-zero $actual"

export RUSTFLAGS="-Clinker=mold -Clinker-flavor=ld"
echo 'building candidates (musl static)'
cargo build --locked --release --target x86_64-unknown-linux-musl 2>&1 | tail -n 1
(cd "$SEATD" && cargo build --locked --release --target x86_64-unknown-linux-musl 2>&1 | tail -n 1)
(cd "$DOAS" && cargo build --locked --release --target x86_64-unknown-linux-musl 2>&1 | tail -n 1)
mkdir -p "$ROOT/.work/combined" "$ROOT/.work/tmp"
export TMPDIR="$ROOT/.work/tmp"
cc -O2 -static -Wall -DUSB_IDS_PATH='"/usr/share/hwdata/usb.ids"' \
  -o "$ROOT/.work/combined/consumer" "$ROOT/tools/udev-consumer.c" \
  $LIBUDEV_ZERO/udev.c $LIBUDEV_ZERO/udev_device.c $LIBUDEV_ZERO/udev_enumerate.c \
  $LIBUDEV_ZERO/udev_list.c $LIBUDEV_ZERO/udev_monitor.c -I$LIBUDEV_ZERO
echo 'check-combined: consumer built (static musl, unpatched fork API)'
cc -std=c11 -O2 -static -D_XOPEN_SOURCE=700 -DLIBSEAT=1 -DSEATD_ENABLED=1 \
  '-DSEATD_DEFAULTPATH="/run/combined-seatd.sock"' \
  -I$SEATD/oracle/include \
  "$ROOT/tools/combined-seat-client.c" \
  $SEATD/oracle/common/connection.c $SEATD/oracle/common/linked_list.c \
  $SEATD/oracle/common/log.c $SEATD/oracle/libseat/backend/seatd.c \
  $SEATD/oracle/libseat/backend/noop.c $SEATD/oracle/libseat/libseat.c \
  -o "$ROOT/.work/combined/seat-client"
echo 'check-combined: seat client built (static musl, oracle libseat)'

TARBALL=alpine-minirootfs-3.20.3-x86_64.tar.gz
if [ ! -f "$ROOT/.work/dl/$TARBALL" ]; then
  echo 'check-combined: minirootfs tarball missing (run tools/build-qemu-guest.sh once)' >&2
  exit 1
fi
GROOT="$ROOT/.work/combined/root"
rm -rf "$GROOT"
mkdir -p "$GROOT"
tar -xzf "$ROOT/.work/dl/$TARBALL" -C "$GROOT"
# Kernel modules must match .work/vmlinuz-virt, which build-qemu-guest.sh
# copies out of .work/guest-root: reuse that root's module tree verbatim.
# Without it the virt kernel has no evdev and mdev creates no event nodes.
if [ ! -d "$ROOT/.work/guest-root/lib/modules" ]; then
  echo 'check-combined: guest modules missing (run tools/build-qemu-guest.sh once)' >&2
  exit 1
fi
mkdir -p "$GROOT/lib"
cp -a "$ROOT/.work/guest-root/lib/modules" "$GROOT/lib/modules"
mkdir -p "$GROOT/usr/local/bin"
cp "$ROOT/target/x86_64-unknown-linux-musl/release/mdevd" "$GROOT/usr/local/bin/mdevd"
cp "$ROOT/target/x86_64-unknown-linux-musl/release/mdevd-coldplug" "$GROOT/usr/local/bin/mdevd-coldplug"
cp "$SEATD/target/x86_64-unknown-linux-musl/release/seatd" "$GROOT/usr/local/bin/seatd"
cp "$DOAS/target/x86_64-unknown-linux-musl/release/doas" "$GROOT/usr/local/bin/doas"
cp "$ROOT/.work/combined/consumer" "$GROOT/usr/local/bin/combined-consumer"
cp "$ROOT/.work/combined/seat-client" "$GROOT/usr/local/bin/combined-seat-client"
cp "$ROOT/guest/combined-init" "$GROOT/init"
chmod +x "$GROOT/init"
cp "$ROOT/.work/vmlinuz-virt" "$ROOT/.work/combined/vmlinuz"
cp "$ROOT/.work/initramfs-virt" "$ROOT/.work/combined/initramfs"
truncate -s 0 "$ROOT/.work/combined/guest.img"
truncate -s 1G "$ROOT/.work/combined/guest.img"
mkfs.ext4 -q -d "$GROOT" "$ROOT/.work/combined/guest.img"

QMP_SOCK="$ROOT/.work/combined/qmp.sock"
CONSOLE="$ROOT/.work/combined/console.log"
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
if [ ! -c /dev/kvm ]; then echo 'check-combined: /dev/kvm missing (need KVM)' >&2; exit 1; fi
qemu-system-x86_64 -M q35 -m 1024 -cpu host -enable-kvm \
  -vga none -display none -device virtio-gpu-pci -device virtio-keyboard-pci \
  -kernel "$ROOT/.work/combined/vmlinuz" -initrd "$ROOT/.work/combined/initramfs" \
  -append "console=tty0 console=ttyS0 root=/dev/vda rootfstype=ext4 rw init=/init" \
  -drive file="$ROOT/.work/combined/guest.img",format=raw,if=virtio \
  -serial file:"$CONSOLE" \
  -qmp unix:"$QMP_SOCK",server=on,wait=off \
  -no-reboot > "$ROOT/.work/combined/qemu.log" 2>&1 &
QEMU_PID=$!
ok=0
i=0
while [ $i -lt 180 ]; do
  if grep -q COMBINED_OK "$CONSOLE" 2>/dev/null; then ok=1; break; fi
  if grep -q COMBINED_FAIL "$CONSOLE" 2>/dev/null; then break; fi
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    if grep -q COMBINED_OK "$CONSOLE" 2>/dev/null; then ok=1; break; fi
    break
  fi
  sleep 1
  i=$((i + 1))
done
if [ $ok != 1 ]; then
  echo 'check-combined: guest proof failed' >&2
  tail -n 30 "$CONSOLE" 2>/dev/null || true
  grep -h COMBINED_FAIL "$CONSOLE" 2>/dev/null || true
  exit 1
fi
for m in COMBINED_MDEVD_OK COMBINED_SEATD_OK COMBINED_DOAS_OK; do
  grep -q "^$m" "$CONSOLE" || { echo "check-combined: $m missing" >&2; exit 1; }
done
if grep -q COMBINED_SEAT_DEVICE_OK "$CONSOLE"; then
  echo 'check-combined: seat device use proven'
else
  echo 'check-combined: seat device use not observed' >&2
  exit 1
fi
i=0
while kill -0 "$QEMU_PID" 2>/dev/null && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
if kill -0 "$QEMU_PID" 2>/dev/null; then echo 'check-combined: QEMU did not exit' >&2; exit 1; fi
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=
echo 'check-combined: OK (mdevd+consumer, seatd admit/restart, doas narrow/deny)'
