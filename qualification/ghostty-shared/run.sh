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
sed "s/LOCAL_ARCHIVE_SHA256/$sha/" "$root/qualification/ghostty-shared/PKGBUILD.xsh" > "$repo/packages/ghostty-custom/PKGBUILD.xsh"
cp "$root/qualification/ghostty-shared/proof.xsh" "$repo/packages/ghostty-custom/proof.xsh"
printf 'Qualification workspace: %s\nArchive SHA-256: %s\n' "$workspace" "$sha"
cd "$repo"
export TMPDIR="$root/.work/tmp"
make profile-test "XSH_ROOT=${XSH_ROOT:-$root/../xsh}"
