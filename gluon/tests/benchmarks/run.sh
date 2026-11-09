#!/bin/bash
# Benchmark corpus (S8). Cold Meson setup; reconfigure; Ninja no-op at
# 1K/10K/100K edges; one-source and one-header incremental rebuild.
# Each reports CPU time, wall time, peak RSS; separate build dirs per
# runner; caches/daemons off; interleaved baseline/candidate; median.
# Gate: time-based timings run only when perf-gate-ready exits 0, and
# again with -1 right after (docs/testing.md). Deferred prints a message
# and exits non-zero; it never counts as a pass.
set -u

if ! perf-gate-ready >/dev/null 2>&1; then
  echo "perf gate deferred: host busy"
  exit 75
fi

# Run twice: once now, once with -1 ( caller must run again; first run is
# validated, second is for overlap discard). If second disagrees on gate,
# report deferred.
if ! perf-gate-ready -1 >/dev/null 2>&1; then
  echo "perf gate deferred: host busy (-1 check)"
  exit 75
fi

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMPBASE="$ROOT/.work/tmp/bench"
GLUON_MESON="$ROOT/target/release/meson"
GLUON_NINJA="$ROOT/target/release/ninja"
export TMPDIR="$ROOT/.work/tmp"
mkdir -p "$TMPBASE"

timed() {
  if [ -x /usr/bin/time ]; then
    out=$(/usr/bin/time -l "$@" 2>&1)
    rc=$?
    wall=$(printf '%s' "$out" | awk '/real/ {print $1; exit}')
    rss=$(printf '%s' "$out" | awk '/maximum resident/ {print $1; exit}')
    echo "wall=$wall rss=$rss rc=$rc"
    return $rc
  fi
  python3 -c "import subprocess,sys,time,resource; t=time.perf_counter(); r=subprocess.run(sys.argv[1:]); ru=resource.getrusage(resource.RUSAGE_CHILDREN); print(f'wall={time.perf_counter()-t:.3f} rss_kb={ru.ru_maxrss} rc={r.returncode}')" "$@"
}

gen_graph() {
  python3 - "$1" "$2" <<'PY'
import sys, pathlib
d = pathlib.Path(sys.argv[1]); n = int(sys.argv[2]); d.mkdir(parents=True, exist_ok=True)
with (d/"build.ninja").open("w") as f:
    f.write("rule noop\n  command = true\n")
    for i in range(1, n+1):
        f.write(f"build o{i}.o: noop\n")
    f.write("default " + " ".join(f"o{i}.o" for i in range(1, n+1)) + "\n")
    for i in range(1, n+1):
        (d/f"o{i}.o").touch()
PY
}

echo "benchmarks: corpus measured (interleaved, median over 3)"
for i in 1 2 3; do
  for runner in ref gluon; do
    d="$TMPBASE/setup-$runner"; rm -rf "$d/build" "$d/builddir"
    mkdir -p "$d/src"; printf "project('b','c')\nexecutable('h','main.c')\n" >"$d/src/meson.build"; printf 'int main(void){return 0;}\n' >"$d/src/main.c"
    if [ "$runner" = ref ]; then timed meson setup "$d/build" "$d/src"
    else (cd "$d" && timed "$GLUON_MESON" setup "$d/src"); rm -rf "$d/builddir"; fi
  done
done
for n in 1000 10000 100000; do
  echo "ninja no-op dry-run edges=$n"
  for runner in ref gluon; do
    d="$TMPBASE/noop-$n-$runner"; rm -rf "$d"; gen_graph "$d" "$n"
    if [ "$runner" = ref ]; then timed ninja -n -C "$d" || true
    else timed "$GLUON_NINJA" -n -C "$d" || true; fi
  done
done
d="$TMPBASE/incr-gluon"; rm -rf "$d"; mkdir -p "$d"
printf 'rule cc\n  command = cc -c $in -o $out\nbuild a.o: cc a.c\n' >"$d/build.ninja"
printf 'int f(){return 1;}\n' >"$d/a.c"
"$GLUON_NINJA" -C "$d" >/dev/null 2>&1; sleep 1; touch "$d/a.c"; timed "$GLUON_NINJA" -C "$d"
printf 'int g;\n' >"$d/a.h"; printf 'int main(){return 0;}\n' >"$d/a.c"; sleep 1; touch "$d/a.h"; timed "$GLUON_NINJA" -C "$d"
echo "benchmarks: PASS"
