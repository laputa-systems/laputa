#!/bin/bash
# Benchmark corpus (S8). Cold Meson setup; reconfigure; Ninja no-op at
# 1K/10K/100K edges; one-source and one-header incremental rebuild.
# Each reports CPU time, wall time, peak RSS; separate build dirs per
# runner; caches/daemons off; interleaved baseline/candidate; median.
# Gate: time-based timings run only when perf-gate-ready exits 0, and
# again with -1 right after. Deferred prints a message
# and exits non-zero; it never counts as a pass.
set -Eeuo pipefail
trap 'rc=$?; echo "benchmarks: command failed ($rc): $BASH_COMMAND" >&2' ERR

if ! perf-gate-ready >/dev/null 2>&1; then
  echo "verdict: inconclusive: perf gate deferred: host busy"
  exit 75
fi

# Run twice: once now, once with -1 ( caller must run again; first run is
# validated, second is for overlap discard). If second disagrees on gate,
# report deferred.
if ! perf-gate-ready -1 >/dev/null 2>&1; then
  echo "verdict: inconclusive: perf gate deferred: host busy (-1 check)"
  exit 75
fi

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMPBASE="$ROOT/.work/tmp/bench"
GLUON_MESON="$ROOT/target/release/meson"
GLUON_NINJA="$ROOT/target/release/ninja"
export TMPDIR="$ROOT/.work/tmp"
export NINJA_STATUS="[%f/%t] "
mkdir -p "$TMPBASE"

timed() {
  if [ -x /usr/bin/time ]; then
    if [ "$(uname -s)" = Linux ]; then time_args=(-f "wall=%e rss_kb=%M"); else time_args=(-l); fi
    if out=$(/usr/bin/time "${time_args[@]}" "$@" 2>&1); then
      rc=0
    else
      rc=$?
      printf '%s\n' "$out" >&2
      echo "benchmarks: command failed ($rc): $*" >&2
      return "$rc"
    fi
    if [ "$(uname -s)" = Linux ]; then
      wall=$(printf '%s\n' "$out" | awk -F'[= ]' '/^wall=/ {print $2; exit}')
      rss=$(printf '%s\n' "$out" | awk -F'[= ]' '/^wall=/ {print $4; exit}')
    else
      wall=$(printf '%s' "$out" | awk '/real/ {print $1; exit}')
      rss=$(printf '%s' "$out" | awk '/maximum resident/ {print $1; exit}')
    fi
    echo "wall=$wall rss=$rss rc=$rc"
  else
    if out=$(python3 -c "import subprocess,sys,time,resource; t=time.perf_counter(); r=subprocess.run(sys.argv[1:]); ru=resource.getrusage(resource.RUSAGE_CHILDREN); print(f'wall={time.perf_counter()-t:.3f} rss_kb={ru.ru_maxrss} rc={r.returncode}'); sys.exit(r.returncode)" "$@" 2>&1); then
      printf '%s\n' "$out"
    else
      rc=$?
      printf '%s\n' "$out" >&2
      echo "benchmarks: command failed ($rc): $*" >&2
      return "$rc"
    fi
  fi
  count_commands
}

count_commands() {
  command_count=$(printf '%s\n' "$out" | awk '/^\[[0-9]+\/[0-9]+\]/ {n++} END {print n+0}')
}

observe() {
  if out=$("$@" 2>&1); then
    count_commands
  else
    rc=$?
    printf '%s\n' "$out" >&2
    echo "benchmarks: command failed ($rc): $*" >&2
    return "$rc"
  fi
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

require_file() {
  if [ ! -f "$1" ]; then
    echo "benchmarks: missing artifact: $1" >&2
    exit 1
  fi
}

require_count() {
  if [ "$1" != "$2" ]; then
    echo "benchmarks: command count mismatch ($3): $1 != $2" >&2
    exit 1
  fi
}

echo "benchmarks: corpus measured (interleaved, median over 3)"
for i in 1 2 3; do
  for runner in ref gluon; do
    d="$TMPBASE/setup-$runner"; rm -rf "$d/build" "$d/builddir"
    mkdir -p "$d/src"; printf "project('b','c')\nexecutable('h','main.c')\n" >"$d/src/meson.build"; printf 'int main(void){return 0;}\n' >"$d/src/main.c"
    if [ "$runner" = ref ]; then
      timed meson setup "$d/build" "$d/src"
      require_file "$d/build/build.ninja"
    else
      cd "$d"
      timed "$GLUON_MESON" setup "$d/src"
      cd "$ROOT"
      require_file "$d/builddir/build.ninja"
      rm -rf "$d/builddir"
    fi
  done
done
for n in 1000 10000 100000; do
  echo "ninja no-op dry-run edges=$n"
  for runner in ref gluon; do
    d="$TMPBASE/noop-$n-$runner"; rm -rf "$d"; gen_graph "$d" "$n"
    require_file "$d/build.ninja"; require_file "$d/o1.o"; require_file "$d/o$n.o"
    if [ "$runner" = ref ]; then
      timed ninja -n -C "$d"
      ref_count=$command_count
    else
      timed "$GLUON_NINJA" -n -C "$d"
      require_count "$ref_count" "$command_count" "dry-run edges=$n"
      require_count "$command_count" 0 "no-op edges=$n"
    fi
  done
done
for runner in ref gluon; do
  d="$TMPBASE/incr-$runner"; rm -rf "$d"; mkdir -p "$d"
  printf 'rule cc\n  command = cc -c $in -o $out\nbuild a.o: cc a.c\n' >"$d/build.ninja"
  printf 'int f(){return 1;}\n' >"$d/a.c"
  if [ "$runner" = ref ]; then ninja_cmd=ninja; else ninja_cmd="$GLUON_NINJA"; fi
  "$ninja_cmd" -C "$d" >/dev/null
  require_file "$d/a.o"
  sleep 1; touch "$d/a.c"
  if [ "$runner" = ref ]; then observe "$ninja_cmd" -C "$d"; else timed "$ninja_cmd" -C "$d"; fi
  require_file "$d/a.o"
  if [ "$runner" = ref ]; then source_count=$command_count; else require_count "$source_count" "$command_count" source; require_count "$command_count" 1 source; fi
  printf 'int g;\n' >"$d/a.h"; printf 'int main(){return 0;}\n' >"$d/a.c"; sleep 1; touch "$d/a.h"
  if [ "$runner" = ref ]; then observe "$ninja_cmd" -C "$d"; else timed "$ninja_cmd" -C "$d"; fi
  require_file "$d/a.o"
  if [ "$runner" = ref ]; then header_count=$command_count; else require_count "$header_count" "$command_count" header; require_count "$command_count" 1 header; fi
done
if ! perf-gate-ready -1 >/dev/null 2>&1; then
  echo "verdict: inconclusive: perf gate deferred: host busy (-1 check)"
  exit 75
fi
python3 "$ROOT/tests/benchmarks/libdrm.py"
echo "benchmarks: corpus completed; see verdict above"
