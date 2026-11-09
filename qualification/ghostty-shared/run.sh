#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'usage: %s /absolute/path/to/ghostty.tar.gz\n' "$0" >&2
  exit 2
fi
root=$(git rev-parse --show-toplevel)
archive=$(realpath "$1")
test -f "$archive"
test "$(uname -m)" = x86_64
git -C "$root" check-ignore -q .work
mkdir -p "$root/.work/tmp"
workspace=$(mktemp -d "$root/.work/tmp/ghostty-shared.XXXXXXXX")
mkdir -p "$workspace/repo"
git -C "$root" archive --format=tar HEAD | tar -xf - -C "$workspace/repo"
repo="$workspace/repo"
mkdir -p "$repo/.out/seed" "$repo/.cache"
cp -al "$root/.out/seed/." "$repo/.out/seed/"
cp -al "$root/.cache/sources" "$repo/.cache/sources"
for dir in artifacts cache host; do
  ln -s "$root/.out/$dir" "$repo/.out/$dir"
done
cp "$archive" "$repo/packages/ghostty-custom/files/ghostty-local.tar.gz"
sha=$(sha256sum "$archive")
sha=${sha%% *}
recipe="$repo/packages/ghostty-custom/PKGBUILD.xsh"
generated="$workspace/PKGBUILD.xsh"
expect_one() {
  local count
  count=$(rg -c -F -- "$2" "$1" || true)
  if [ "$count" != 1 ]; then
    printf 'run.sh: expected one line matching %s in %s, found %s\n' "$2" "$1" "${count:-0}" >&2
    exit 1
  fi
}
sed \
  -e 's|source: p"https://[^"]*ghostty-custom-ARCH-linux-musl\.tar\.gz => ghostty"|source: p"files/ghostty-local.tar.gz => ghostty"|' \
  -e "/arch: \"x86_64\",/{n;s|sha256: \"[0-9a-f]*\"|sha256: \"$sha\"|;}" \
  "$recipe" > "$generated"
expect_one "$generated" 'source: p"files/ghostty-local.tar.gz => ghostty"'
expect_one "$generated" "sha256: \"$sha\""
mv "$generated" "$recipe"
printf 'Qualification workspace: %s\nArchive SHA-256: %s\n' "$workspace" "$sha"
cd "$repo"
export TMPDIR="$root/.work/tmp"
make profile-test "XSH_ROOT=${XSH_ROOT:-$root/../xsh}"
