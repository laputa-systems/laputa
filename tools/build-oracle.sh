#!/bin/sh
# Reproducible test-only C-oracle build. Everything lands in .work/oracle;
# the repo itself is never modified. Rerunning must converge (idempotent).
# Steps: fetch+build skalibs, copy+configure+build mdevd, build dump-run
# with pattern instrumentation (PAT lines on stderr, in compile order).
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
V=$ROOT/.work/vendor
O=$ROOT/.work/oracle
SKALIBS_VER=2.15.1.0

mkdir -p "$V" "$O"
if [ ! -f "$V/skalibs.tar.gz" ]; then
  curl -sL -o "$V/skalibs.tar.gz" "https://skarnet.org/software/skalibs/skalibs-$SKALIBS_VER.tar.gz"
fi
if [ ! -d "$V/skalibs-$SKALIBS_VER" ]; then
  tar xzf "$V/skalibs.tar.gz" -C "$V"
fi
if [ ! -f "$V/sysdeps-root/lib/skalibs/sysdeps/target" ]; then
  (cd "$V/skalibs-$SKALIBS_VER" && ./configure --prefix="$V/sysdeps-root" --enable-shared --disable-static >/dev/null && make -j32 >/dev/null && make install >/dev/null)
  echo "oracle: skalibs built"
fi
if [ ! -d "$O/src-tree" ]; then
  mkdir -p "$O/src-tree"
  cp -r src doc package tools configure INSTALL Makefile AUTHORS COPYING DCO NEWS "$O/src-tree/"
fi
if [ ! -x "$O/src-tree/mdevd" ]; then
  (cd "$O/src-tree" && ./configure --with-sysdeps="$V/sysdeps-root/lib/skalibs/sysdeps" --with-include="$V/sysdeps-root/include" --with-dynlib="$V/sysdeps-root/lib" --disable-allstatic --prefix="$O/prefix" >/dev/null && make -j32 >/dev/null)
  echo "oracle: mdevd built"
fi
# Instrumented copy for the dump harness (PAT lines before each regcomp).
cp "$O/src-tree/src/mdevd/mdevd.c" "$O/mdevd_impl.c"
cp "$O/src-tree/src/mdevd/mdevd-internal.h" "$O/"
for f in mdevd_uevent_getvar.c mdevd_netlink_init.c mdevd_uevent_read.c; do
  cp "$O/src-tree/src/mdevd/$f" "$O/"
done
python3 - "$O/mdevd_impl.c" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old_env = "int r = regcomp(&envmatch[j].re, s + mark, REG_EXTENDED) ;"
new_env = '{ fprintf(stderr, "PAT %s\\n", s + mark); } int r = regcomp(&envmatch[j].re, s + mark, REG_EXTENDED) ;'
old_dev = "int r = regcomp(&script[i].devmatch.devre, s + mark, REG_EXTENDED) ;"
new_dev = '{ fprintf(stderr, "PAT %s\\n", s + mark); } int r = regcomp(&script[i].devmatch.devre, s + mark, REG_EXTENDED) ;'
assert s.count(old_env) == 1 and s.count(old_dev) == 1, "regcomp sites changed"
open(p, "w").write(s.replace(old_env, new_env).replace(old_dev, new_dev))
print("oracle: instrumented regcomp sites")
EOF
VLIB=$V/sysdeps-root
gcc -O2 -o "$O/dump-run" "$O/dump-run.c" "$O/mdevd_uevent_getvar.c" "$O/mdevd_netlink_init.c" "$O/mdevd_uevent_read.c" -I"$O" -I"$O/src-tree/src/include" -I"$VLIB/include" -L"$VLIB/lib" -lskarnet "-Wl,-rpath,$VLIB/lib"
echo "oracle: dump-run built"
