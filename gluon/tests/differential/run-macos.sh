#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$root/.work/tmp"
scratch=$(mktemp -d "$root/.work/tmp/macos-reference.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
export TMPDIR="$scratch"

pin() {
  awk -v key="$1" -F= '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$root/tests/upstream/PINS"
}

meson_url=$(pin MESON_WHEEL_URL)
ninja_url=$(pin NINJA_MAC_URL)
wheel=${meson_url##*/}
cd "$scratch"
curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --retry 3 \
  --output "$wheel" "$meson_url"
curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --retry 3 \
  --output ninja-mac.zip "$ninja_url"
printf '%s  %s\n' "$(pin MESON_WHEEL_SHA256)" "$wheel" "$(pin NINJA_MAC_SHA256)" ninja-mac.zip |
  shasum -a 256 -c
unzip -q ninja-mac.zip ninja -d bin
python3 -m venv venv
venv/bin/python -m pip install --disable-pip-version-check --no-index --no-deps "$wheel"
PATH="$scratch/venv/bin:$scratch/bin:$PATH" bash "$root/tests/differential/run.sh"
awk '/^SKIP / && $2 !~ /^meson\/wayland-(find-protocol|scan-xml)$/ { print; skipped = 1 }
     END { exit skipped }' "$root/.work/tmp/diff/results.log"
