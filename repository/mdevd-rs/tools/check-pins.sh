#!/bin/sh
# R0: verify reference pins. Plain run checks local ancestry + fixture presence.
# With --live, also re-verifies the libudev-zero remote HEAD over the network.
set -eu
BASE_MDEVD_RS=eac18f5
PIN_LIBUDEV_ZERO=8f1d3d0624496f1c4967f18d6afaddbd552d8bce
if ! git merge-base --is-ancestor "$BASE_MDEVD_RS" HEAD; then
  echo "check-pins: base $BASE_MDEVD_RS is not an ancestor of HEAD" >&2
  exit 1
fi
echo "check-pins: base $BASE_MDEVD_RS OK"
if [ "${1:-}" = "--live" ]; then
  live=$(git ls-remote https://github.com/laputa-systems/libudev-zero HEAD | awk '{print $1}')
  if [ "$live" != "$PIN_LIBUDEV_ZERO" ]; then
    echo "check-pins: libudev-zero moved: $live (recorded $PIN_LIBUDEV_ZERO)" >&2
    exit 1
  fi
  echo "check-pins: libudev-zero $PIN_LIBUDEV_ZERO OK (live)"
else
  echo "check-pins: libudev-zero $PIN_LIBUDEV_ZERO recorded (use --live to re-verify)"
fi
for f in tests/fixtures/pins.txt tests/fixtures/laputa-mdev.conf tests/fixtures/laputa-invocation.txt tests/fixtures/hook-mdev.conf tests/fixtures/bad-mdev.conf; do
  if [ ! -f "$f" ]; then
    echo "check-pins: missing $f" >&2
    exit 1
  fi
done
echo "check-pins: fixtures OK"
