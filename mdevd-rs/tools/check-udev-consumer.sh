#!/bin/sh
# P4 proof: a real C consumer against the pinned libudev-zero fork receives
# add/change/remove notifications published by the Rust sender and observes
# the expected device state. Multicast needs a capable netns, so the live
# exchange runs under `unshare -U -n -r` (verified available); the parent
# namespace only builds.
#
# Fails loudly when any stage is skipped: the live tests print exchange
# markers that are grepped below.
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
PIN=8f1d3d0624496f1c4967f18d6afaddbd552d8bce
REF=$ROOT/.work/ref/libudev-zero

if [ -n "${LIBUDEV_ZERO_SRC:-}" ] && [ -d "$LIBUDEV_ZERO_SRC" ]; then
  mkdir -p "$ROOT/.work/ref"
  rm -rf "$REF"
  ln -sfn "$LIBUDEV_ZERO_SRC" "$REF"
  echo "check-udev-consumer: using local LIBUDEV_ZERO_SRC=$LIBUDEV_ZERO_SRC"
elif [ -d "$HOME/d/libudev-zero" ]; then
  mkdir -p "$ROOT/.work/ref"
  rm -rf "$REF"
  ln -sfn "$HOME/d/libudev-zero" "$REF"
  echo "check-udev-consumer: using local ~/d/libudev-zero"
elif [ ! -d "$REF" ]; then
  git clone --quiet https://github.com/laputa-systems/libudev-zero "$REF"
fi
if [ -L "$REF" ]; then
  actual=$(cd "$REF" && git rev-parse HEAD)
else
  (cd "$REF" && git fetch --quiet origin && git checkout --quiet "$PIN")
  actual=$(cd "$REF" && git rev-parse HEAD)
fi
if [ "$actual" != "$PIN" ]; then
  echo "check-udev-consumer: pin mismatch: $actual != $PIN" >&2
  exit 1
fi
echo "check-udev-consumer: fork at $PIN"

# shellcheck disable=SC2086
cc -O2 -Wall -DUSB_IDS_PATH='"/usr/share/hwdata/usb.ids"' -o "$ROOT/.work/ref/consumer" "$ROOT/tools/udev-consumer.c" \
  $REF/udev.c $REF/udev_device.c $REF/udev_enumerate.c $REF/udev_list.c $REF/udev_monitor.c \
  -I$REF
echo "check-udev-consumer: consumer built (unpatched fork API)"

export CONSUMER_BIN="$ROOT/.work/ref/consumer"
export CONSUMER_OUT="$ROOT/.work/tmp/consumer.out"
rm -f "$CONSUMER_OUT"

echo "--- Rust multicast self-exchange under unshare:"
unshare -U -n -r cargo test --locked -q --test publish publish_live_multicast -- --exact --nocapture 2>&1 | tee "$ROOT/.work/tmp/live-mcast.log"
grep -q "live-multicast: exchanged" "$ROOT/.work/tmp/live-mcast.log" || {
  echo "check-udev-consumer: live multicast did not run" >&2
  exit 1
}

echo "--- C consumer exchange under unshare:"
unshare -U -n -r cargo test --locked -q --test publish publish_live_consumer -- --exact --nocapture 2>&1 | tee "$ROOT/.work/tmp/live-consumer.log"
grep -q "live-consumer: verified" "$ROOT/.work/tmp/live-consumer.log" || {
  echo "check-udev-consumer: live consumer exchange did not verify" >&2
  exit 1
}
echo "check-udev-consumer: OK"
