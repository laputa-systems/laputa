#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .work/tmp
scratch=$(mktemp -d "$PWD/.work/tmp/build-qemu.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/bin" "$scratch/mdevd/tools" "$scratch/mdevd/guest" \
  "$scratch/mdevd/.work/dl/apk/main" "$scratch/mdevd/.work/guest-root/etc" \
  "$scratch/mdevd/target/x86_64-unknown-linux-musl/release"
cp tools/build-qemu-guest.sh "$scratch/mdevd/tools/"
printf '%064d main/example.apk\n' 0 > "$scratch/mdevd/guest/packages.sha256"
printf '3.20.3\n' > "$scratch/mdevd/.work/guest-root/etc/alpine-release"
touch "$scratch/mdevd/.work/dl/alpine-minirootfs-3.20.3-x86_64.tar.gz" "$scratch/mdevd/.work/dl/apk/main/example.apk"
printf '#!/bin/sh\nexit 0\n' > "$scratch/mdevd/target/x86_64-unknown-linux-musl/release/mdevd"
chmod +x "$scratch/mdevd/target/x86_64-unknown-linux-musl/release/mdevd"
printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/sha256sum"
printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/apk"
printf '#!/bin/sh\necho build-failed >&2\nexit 42\n' > "$scratch/bin/cargo"
chmod +x "$scratch/bin/"*
if PATH="$scratch/bin:$PATH" /bin/sh "$scratch/mdevd/tools/build-qemu-guest.sh" > "$scratch/output" 2>&1; then
  echo 'build-qemu-guest accepted a failed build' >&2
  exit 1
fi
rg -q 'build-failed' "$scratch/output"
if [ -e "$scratch/mdevd/.work/guest-root/usr/local/bin/mdevd" ]; then
  echo 'build-qemu-guest copied a stale executable' >&2
  exit 1
fi
echo 'build-qemu-guest stops before copying stale executables'
