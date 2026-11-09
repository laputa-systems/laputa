#!/bin/sh
# Laputa parity: configures, builds and installs each Meson package Laputa
# ships from its cached upstream source, once with reference Meson 1.12.1
# and samu and once with gluon, and compares the installed trees (paths,
# modes, symlink targets). A package listed in expected-fail must fail; any
# other package must match. Usage: run.sh [PACKAGE...]; LAPUTA_SOURCE_CACHE
# names the source cache when running from a worktree.
set -u
GLUON=$(cd "$(dirname "$0")/../.." && pwd)
LAPUTA=$(cd "$GLUON/.." && pwd)
HERE=$GLUON/tests/laputa
WORK=$GLUON/.work/tmp/laputa
MESON=$GLUON/target/release/meson
NINJA=$GLUON/target/release/ninja
LEDGER=$HERE/expected-fail
SOURCES=${LAPUTA_SOURCE_CACHE:-$LAPUTA/.cache/sources}
export LC_ALL=C TZ=UTC
[ -x "$MESON" ] && [ -x "$NINJA" ] || { echo "build gluon first: cargo build --release --locked" >&2; exit 2; }
packages=${*:-$(rg -v '^#|^$' "$HERE/packages" | cut -d' ' -f1)}

tree() {
  ( cd "$1" && fd -H -u . | sort | while read -r f; do
      if [ -L "$f" ]; then echo "$f -> $(readlink "$f")"
      elif [ -d "$f" ]; then echo "$f/"
      else echo "$f $(stat -c %a "$f")"; fi
    done )
}

run_impl() {
  impl=$1 src=$2 out=$3; shift 3
  if [ "$impl" = ref ]; then m=meson n=samu; else m=$MESON n=$NINJA; fi
  b=$out/$impl-build d=$out/$impl-dest
  timeout 900 "$m" setup --prefix=/usr --libdir=lib "$@" "$b" "$src" > "$out/$impl-setup.log" 2>&1 || { echo setup; return; }
  timeout 3600 "$n" -C "$b" > "$out/$impl-build.log" 2>&1 || { echo build; return; }
  DESTDIR=$d timeout 900 "$m" install -C "$b" > "$out/$impl-install.log" 2>&1 || { echo install; return; }
  tree "$d" > "$out/$impl-tree.txt"
  echo ok
}

status=0
for pkg in $packages; do
  recipe=$LAPUTA/packages/$pkg/PKGBUILD.xsh
  sha=$(rg -o 'sha256: "[0-9a-f]{64}"' "$recipe" | head -1 | rg -o '[0-9a-f]{64}')
  archive=$SOURCES/sha256/$sha
  [ -f "$archive" ] || { echo "$pkg: source $sha not in the Laputa source cache (make fetch)"; status=1; continue; }
  opts=$(rg "^$pkg " "$HERE/packages" | cut -d' ' -f2-)
  out=$WORK/$pkg; rm -rf "$out"; mkdir -p "$out/src"
  tar -xf "$archive" -C "$out/src"
  src=$(fd -t d -d 1 . "$out/src" | head -1); src=${src%/}
  ref=$(run_impl ref "$src" "$out" $opts)
  glu=$(run_impl glu "$src" "$out" $opts)
  if [ "$ref" != ok ]; then verdict="reference $ref failed"
  elif [ "$glu" != ok ]; then verdict="gluon $glu failed"
  elif diff "$out/ref-tree.txt" "$out/glu-tree.txt" > "$out/tree.diff"; then verdict=match
  else verdict="installed trees differ ($(rg -c '^[<>]' "$out/tree.diff") lines)"; fi
  listed=$(rg -c "^$pkg\b" "$LEDGER" 2>/dev/null || echo 0)
  case "$verdict:$listed" in
    match:0) echo "PASS $pkg" ;;
    match:*) echo "UNEXPECTED PASS $pkg (remove it from expected-fail)"; status=1 ;;
    "reference "*) echo "SKIP $pkg: $verdict (see $out/ref-*.log)" ;;
    *:0) echo "FAIL $pkg: $verdict (see $out)"; status=1 ;;
    *) echo "XFAIL $pkg: $verdict" ;;
  esac
done
exit $status
