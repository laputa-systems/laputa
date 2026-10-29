#!/bin/sh
# Build the mdevd QEMU guest: pinned Alpine minirootfs + boot packages and
# musl-static Rust daemons, plus the guest init that proves daemon-driven
# node creation from real kernel uevents.
# Prior art: tinyland harness/build-guest.sh + prepare-guest.sh (read-only).
# All writes stay under this repo's .work/.
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD/.work/guest-root
case "$ROOT" in "$PWD"/.work/*) ;; *) echo 'guest root must be inside .work' >&2; exit 2 ;; esac
mkdir -p .work/dl/apk .work/tmp
export TMPDIR="$PWD/.work/tmp"
MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
TARBALL=alpine-minirootfs-3.20.3-x86_64.tar.gz
if [ ! -f ".work/dl/$TARBALL" ]; then
  curl --fail --location "$MIRROR/v3.20/releases/x86_64/$TARBALL" --output ".work/dl/$TARBALL.part"
  mv ".work/dl/$TARBALL.part" ".work/dl/$TARBALL"
fi
printf '%s  %s\n' d4e6fd67dcf75e40c451560ac7265166c2b72a0f38ddc9aae756a7de3d1efa0c ".work/dl/$TARBALL" | sha256sum -c -
if [ ! -f "$ROOT/etc/alpine-release" ]; then
  mkdir -p "$ROOT"
  tar -xzf ".work/dl/$TARBALL" -C "$ROOT"
fi
if [ "$(cat "$ROOT/etc/alpine-release")" != 3.20.3 ]; then echo 'wrong guest rootfs release' >&2; exit 1; fi
APKS=
while read -r DIGEST PACKAGE; do
  case "$DIGEST" in ????????????????????????????????????????????????????????????????) ;; *) echo 'invalid guest package lock entry' >&2; exit 1 ;; esac
  case "$PACKAGE" in main/*|community/*) ;; *) echo 'invalid guest package lock entry' >&2; exit 1 ;; esac
  TARGET="$PWD/.work/dl/apk/$PACKAGE"
  if [ ! -f "$TARGET" ]; then
    REPOSITORY="${PACKAGE%%/*}"
    mkdir -p "${TARGET%/*}"
    curl --fail --location "$MIRROR/v3.20/$REPOSITORY/x86_64/${PACKAGE#*/}" --output "$TARGET.part"
    mv "$TARGET.part" "$TARGET"
  fi
  APKS="$APKS $TARGET"
done < guest/packages.sha256
if [ -z "$APKS" ]; then echo 'empty guest package lock' >&2; exit 1; fi
(cd .work/dl/apk && sha256sum -c "$OLDPWD/guest/packages.sha256")
apk --keys-dir "$ROOT/etc/apk/keys" verify $APKS
# shellcheck disable=SC2086
apk --root "$ROOT" --repositories-file /dev/null --no-network --keys-dir "$ROOT/etc/apk/keys" \
  --initdb --arch x86_64 --usermode add $APKS
echo GUEST_PACKAGES_VERIFIED
echo 'building mdevd (musl static)'
cargo build --locked --release --target x86_64-unknown-linux-musl 2>&1 | tail -n 3
mkdir -p "$ROOT/usr/local/bin"
cp target/x86_64-unknown-linux-musl/release/mdevd "$ROOT/usr/local/bin/mdevd"
cp target/x86_64-unknown-linux-musl/release/mdevd-coldplug "$ROOT/usr/local/bin/mdevd-coldplug"
cp guest/init "$ROOT/init"
chmod +x "$ROOT/init"
cp "$ROOT/boot/vmlinuz-virt" .work/vmlinuz-virt
cp "$ROOT/boot/initramfs-virt" .work/initramfs-virt
echo 'building disk image'
truncate -s 0 .work/guest.img
truncate -s 1G .work/guest.img
mkfs.ext4 -q -d "$ROOT" .work/guest.img
echo BUILD_QEMU_GUEST_OK
