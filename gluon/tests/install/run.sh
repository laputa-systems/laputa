#!/bin/sh
# Install parity: configure, build and install fixtures with a versioned
# shared library, an executable linked against it, headers in a subdir and a
# pkgconfig file, once with reference Meson + samu and once with gluon, and
# compare the installed trees and the installed binaries' RPATH/RUNPATH. The
# fixtures run without rpath, with an explicit install_rpath and with a
# build-only build_rpath that installation must drop.
set -eu
GLUON=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$GLUON/tests/install/fixture
FIX_RPATH=$GLUON/tests/install/fixture-rpath
FIX_BUILD_RPATH=$GLUON/tests/install/fixture-build-rpath
WORK=$GLUON/.work/tmp/install
MESON=$GLUON/target/release/meson
NINJA=$GLUON/target/release/ninja
export LC_ALL=C TZ=UTC

command -v meson >/dev/null 2>&1 && command -v samu >/dev/null 2>&1 || {
  echo "SKIP install fixture: reference meson/samu not found"
  exit 0
}
command -v readelf >/dev/null 2>&1 || {
  echo "SKIP install fixture: readelf not found"
  exit 0
}
[ -x "$MESON" ] && [ -x "$NINJA" ] || {
  echo "build gluon first: cargo build --release --locked" >&2
  exit 2
}

rm -rf "$WORK"

tree() {
  (
    cd "$1"
    fd -H -u . | sort | while IFS= read -r f; do
      if [ -L "$f" ]; then
        echo "$f -> $(readlink "$f")"
      elif [ -d "$f" ]; then
        echo "$f/"
      else
        echo "$f $(stat -c %a "$f")"
      fi
    done
  )
}

dynamic_tags() {
  (
    cd "$1"
    fd -H -u -t f . | sort | while IFS= read -r f; do
      tags=$(readelf -d "$f" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)
      if [ -n "$tags" ]; then
        printf '%s %s\n' "$f" "$tags"
      fi
    done
  )
}

run_impl() {
  impl=$1
  src=$2
  out=$3
  if [ "$impl" = ref ]; then
    m=meson
    n=samu
  else
    m=$MESON
    n=$NINJA
  fi
  b=$out/$impl-build
  d=$out/$impl-dest
  "$m" setup --prefix=/usr --libdir=lib "$b" "$src" >"$out/$impl-setup.log" 2>&1
  "$n" -C "$b" >"$out/$impl-build.log" 2>&1
  DESTDIR=$d "$m" install -C "$b" >"$out/$impl-install.log" 2>&1
  tree "$d" >"$out/$impl-tree.txt"
  dynamic_tags "$d" >"$out/$impl-dynamic.txt"
}

run_case() {
  name=$1
  src=$2
  out=$WORK/$name
  rm -rf "$out"
  mkdir -p "$out/src"
  cp -R "$src/." "$out/src/"

  run_impl ref "$out/src" "$out"
  run_impl glu "$out/src" "$out"

  failed=0
  if ! diff "$out/ref-tree.txt" "$out/glu-tree.txt" >"$out/tree.diff"; then
    echo "FAIL install fixture ($name): installed trees differ (see $out/tree.diff)" >&2
    cat "$out/tree.diff" >&2
    failed=1
  fi
  if ! diff "$out/ref-dynamic.txt" "$out/glu-dynamic.txt" >"$out/dynamic.diff"; then
    echo "FAIL install fixture ($name): RPATH/RUNPATH differ (see $out/dynamic.diff)" >&2
    cat "$out/dynamic.diff" >&2
    failed=1
  fi
  if [ "$failed" = 0 ]; then
    echo "PASS install fixture ($name)"
  fi
  return "$failed"
}

status=0
run_case default "$FIX" || status=1
run_case install-rpath "$FIX_RPATH" || status=1
run_case build-rpath "$FIX_BUILD_RPATH" || status=1
exit $status
