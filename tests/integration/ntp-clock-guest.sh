#!/usr/bin/env bash
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
mode=${1:?usage: ntp-clock-guest.sh behind|ahead|jump|pause|nts|frequency|chrony-behind|chrony-ahead HOST_XSH SEED ARTIFACTS IMAGE [CHRONYD CHRONYC]}
xsh=$(realpath "${2:?host xsh}")
seed=$(realpath "${3:?seed directory}")
artifacts=$(realpath "${4:?artifact store}")
image=${5:?package-tools image}
case "$mode" in behind|ahead|jump|pause|nts|frequency|chrony-behind|chrony-ahead) ;; *) exit 2 ;; esac
git -C "$repo" check-ignore -q .work/
mkdir -p "$repo/.work/tmp"
work=$(mktemp -d "$repo/.work/tmp/ntp-guest.XXXXXXXX")
trap 'printf "guest evidence: %s\n" "$work"' EXIT
snapshot="$work/repository"
output="$snapshot/.work/output"
input="$snapshot/.work/input-root"
mkdir -p "$snapshot" "$output" "$input/inputs" "$snapshot/.out/seed" "$snapshot/.out/artifacts" "$snapshot/.out/cache/linux-kbuild"
git -C "$repo" archive HEAD | tar -xf - -C "$snapshot"
cp -a --reflink=auto "$seed" "$snapshot/.out/seed/x86_64"
cp -a --reflink=auto "$artifacts" "$snapshot/.out/artifacts/x86_64"
python3 - "$snapshot/profiles/qemu-self-hosting.xsh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '["baselayout", "xsh", "laputa-pm", "xinit"]'
assert text.count(old) == 1 and text.count('qemu_memory: "12G"') == 1
text = text.replace(old, '["baselayout", "xsh", "laputa-pm", "xinit", "ntpd-rs", "ca-certificates"]')
path.write_text(text.replace('qemu_memory: "12G"', 'qemu_memory: "4G"'))
PY
mkdir -p "$snapshot/.work/tmp"
TMPDIR="$snapshot/.work/tmp" XSH_MODULE_PATH="$snapshot" XSH_HOST="$xsh" "$xsh" "$snapshot/seed/self_hosting_profile.xsh" -- \
  "$snapshot" "$snapshot/.out/artifacts/x86_64" "$output" "$image"
channel=$(jaq --from toml -r '.toolchain.channel' "$snapshot/ntpd-rs/rust-toolchain.toml")
rustc=$(rustup which rustc --toolchain "$channel")
TMPDIR="$snapshot/.work/tmp" kache "$rustc" --target x86_64-unknown-linux-musl \
  -C linker=mold -C linker-flavor=ld \
  "$snapshot/tests/integration/fixtures/ntp-clock-server.rs" -o "$input/inputs/ntp-clock-server"
cp "$snapshot/tests/integration/fixtures/ntp-clock-guest.xsh" "$input/inputs/entry.xsh"
if test "$mode" = frequency; then
  cc -dumpmachine | rg -q 'musl$'
  cc -static -fuse-ld=mold "$snapshot/tests/integration/fixtures/ntp-frequency-check.c" -o "$input/inputs/ntp-frequency-check"
  cp "$snapshot/tests/integration/fixtures/ntp-frequency-guest.xsh" "$input/inputs/entry.xsh"
fi
if test "$mode" = chrony-behind || test "$mode" = chrony-ahead; then
  cp "${6:?chronyd binary}" "$input/inputs/chronyd"
  cp "${7:?chronyc binary}" "$input/inputs/chronyc"
  cp "$snapshot/tests/integration/fixtures/chrony-oracle-guest.xsh" "$input/inputs/entry.xsh"
  cp "$snapshot/tests/integration/fixtures/chrony-oracle-service.xsh" "$input/inputs/chrony-oracle.xsh"
  cp "$snapshot/tests/integration/fixtures/chrony-oracle-launch.xsh" "$input/inputs/chrony-launch.xsh"
fi
if test "$mode" = nts; then
  TMPDIR="$snapshot/.work/tmp" CARGO_TARGET_DIR="$work/nts-target" RUSTC_WRAPPER=kache \
    RUSTFLAGS='-C linker=mold -C linker-flavor=ld' cargo "+$channel" build --locked --offline -j 2 \
    --target x86_64-unknown-linux-musl --manifest-path "$snapshot/tests/integration/fixtures/nts-clock-server/Cargo.toml"
  cp "$work/nts-target/x86_64-unknown-linux-musl/debug/nts-clock-server" "$input/inputs/nts-clock-server"
  cp "$snapshot/ntpd-rs/ntp-proto/test-keys/"{testca.pem,end.fullchain.pem,end.key} "$input/inputs/"
  touch "$input/inputs/nts-mode"
fi
if test "$mode" = jump; then touch "$input/inputs/jump-mode"; fi
if test "$mode" = ahead || test "$mode" = chrony-ahead; then touch "$input/inputs/ahead-mode"; fi
if test "$mode" = pause; then touch "$input/inputs/pause-mode"; fi
truncate -s 128M "$output/inputs.ext4"
truncate -s 64M "$output/output.ext4"
/sbin/mkfs.ext4 -q -F -d "$input" "$output/inputs.ext4"
/sbin/mkfs.ext4 -q -F "$output/output.ext4"
XSH_MODULE_PATH="$snapshot" "$xsh" "$snapshot/tests/integration/ntp-clock-boot.xsh" -- \
  "$snapshot" "$output" "$repo/.work/ntp-$$.sock"
if test "$mode" = frequency; then
  cp "$output/console.log" "$output/frequency-first-boot.log"
  XSH_MODULE_PATH="$snapshot" "$xsh" "$snapshot/tests/integration/ntp-clock-boot.xsh" -- \
    "$snapshot" "$output" "$repo/.work/ntp-$$.sock"
fi
