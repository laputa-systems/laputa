#!/bin/sh
# Install parity: configure, build and install a fixture with a versioned
# shared library, headers in a subdir and a pkgconfig file, once with
# reference Meson + samu and once with gluon, and compare the installed trees.
set -eu
GLUON=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$GLUON/tests/install/fixture
WORK=$GLUON/.work/tmp/install
MESON=$GLUON/target/release/meson
NINJA=$GLUON/target/release/ninja
export LC_ALL=C TZ=UTC

command -v meson >/dev/null 2>&1 && command -v samu >/dev/null 2>&1 || {
  echo "SKIP install fixture: reference meson/samu not found"
  exit 0
}
[ -x "$MESON" ] && [ -x "$NINJA" ] || {
  echo "build gluon first: cargo build --release --locked" >&2
  exit 2
}

rm -rf "$WORK"
mkdir -p "$WORK/src"
cp -R "$FIX/." "$WORK/src/"

run_impl() {
  impl=$1
  if [ "$impl" = ref ]; then
    m=meson
    n=samu
  else
    m=$MESON
    n=$NINJA
  fi
  b=$WORK/$impl-build
  d=$WORK/$impl-dest
  "$m" setup --prefix=/usr --libdir=lib "$b" "$WORK/src" >"$WORK/$impl-setup.log" 2>&1
  "$n" -C "$b" >"$WORK/$impl-build.log" 2>&1
  DESTDIR=$d "$m" install -C "$b" >"$WORK/$impl-install.log" 2>&1
  (
    cd "$d"
    fd -H -u . | sort | while IFS= read -r f; do
      if [ -L "$f" ]; then
        echo "$f -> $(readlink "$f")"
      elif [ -d "$f" ]; then
        echo "$f/"
      else
        echo "$f $(stat -c %a "$f")"
      fi
    done
  ) >"$WORK/$impl-tree.txt"
}

run_impl ref
run_impl glu

if diff "$WORK/ref-tree.txt" "$WORK/glu-tree.txt" >"$WORK/tree.diff"; then
  echo "PASS install fixture"
  exit 0
fi
echo "FAIL install fixture: installed trees differ (see $WORK/tree.diff)" >&2
cat "$WORK/tree.diff" >&2
exit 1
