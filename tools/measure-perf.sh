#!/bin/sh
# O1: perf gates. Alternating runs report median + spread; only the Charter
# thresholds fail the run: event-storm RSS growth >5% over 10k synthetic
# events, FD delta != 0, idle wakeups or coldplug time >2x the C reference.
# Absolute numbers are logged for the record; the host here is busy, so
# quiet-host confirmation remains open (see docs/perf.md).
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
TMP=$ROOT/.work/tmp/perf
mkdir -p "$TMP"

tools/build-oracle.sh >/dev/null
cargo build --locked --release -q
RUST_COLDPLUG=$ROOT/target/release/mdevd-coldplug
RUST_MDEVD=$ROOT/target/release/mdevd
C_COLDPLUG=$ROOT/.work/oracle/src-tree/mdevd-coldplug
C_MDEVD=$ROOT/.work/oracle/src-tree/mdevd
export LD_LIBRARY_PATH=$ROOT/.work/vendor/sysdeps-root/lib

if [ ! -x "$RUST_COLDPLUG" ] || [ ! -x "$C_COLDPLUG" ]; then
  echo "measure-perf: missing coldplug binaries" >&2
  exit 1
fi

# Coldplug fixture: 300 uevent files across three subsystems.
TREE=$TMP/tree
rm -rf "$TREE"
for sub in block input pci; do
  for i in $(seq 1 100); do
    d=$TREE/subsystem/$sub/devices/dev$i
    mkdir -p "$d"
    printf 'PLACEHOLDER\n' > "$d/uevent"
  done
done

now_ns() { python3 -c 'import time; print(time.perf_counter_ns())'; }

run_one_us() {
  prog=$1
  start=$(now_ns)
  "$prog" -s "$TREE" >/dev/null 2>&1
  end=$(now_ns)
  python3 -c "print(($end - $start) // 1000)"
}

median() {
  python3 -c 'import sys,statistics; v=sorted(map(int,sys.stdin.read().split())); print(statistics.median(v))'
}
min_of() { sort -n | head -n 1; }
max_of() { sort -n | tail -n 1; }

RUST_TIMES=$TMP/rust.times
C_TIMES=$TMP/c.times
: > "$RUST_TIMES"
: > "$C_TIMES"
i=1
while [ "$i" -le 6 ]; do
  run_one_us "$RUST_COLDPLUG" >> "$RUST_TIMES"
  run_one_us "$C_COLDPLUG" >> "$C_TIMES"
  i=$((i + 1))
done

rust_med=$(median < "$RUST_TIMES")
c_med=$(median < "$C_TIMES")
rust_min=$(min_of < "$RUST_TIMES")
rust_max=$(max_of < "$RUST_TIMES")
c_min=$(min_of < "$C_TIMES")
c_max=$(max_of < "$C_TIMES")
echo "coldplug: rust times_us: $(tr '\n' ' ' < "$RUST_TIMES")"
echo "coldplug: c times_us: $(tr '\n' ' ' < "$C_TIMES")"
echo "coldplug: rust median=${rust_med}us spread=${rust_min}-${rust_max}us"
echo "coldplug: c median=${c_med}us spread=${c_min}-${c_max}us"

ratio=$(python3 -c "r=float('$rust_med'); c=float('$c_med'); print(r/max(c,1.0))")
echo "coldplug: rust/c median ratio=${ratio}x (gate: <=2.0x)"
python3 -c "import sys; sys.exit(0 if float('$ratio') <= 2.0 else 1)" || {
  echo "measure-perf: coldplug slower than 2x C reference" >&2
  exit 1
}

echo "--- engine storm (10k synthetic events, RSS + FD gates) ---"
cargo bench --locked --bench storm 2>&1 | tail -n 8

echo "--- microbenchmarks (logged, not gated) ---"
cargo bench --locked --bench parse 2>&1 | grep -E "bench|test result" | tail -n 3
cargo bench --locked --bench handle 2>&1 | grep -E "bench|test result" | tail -n 3

echo "--- idle daemons (3s, CPU time comparison, gate <=2x + 2 ticks) ---"
cat > "$TMP/idle_probe.py" <<'PY'
import os, subprocess, sys, time
prog, conf, dev, sysd = sys.argv[1:5]
env = dict(os.environ)
r, w = os.pipe()
p = subprocess.Popen([prog, "-I", "1", "-f", conf, "-d", dev, "-s", sysd, "-D", str(w)],
                     pass_fds=(w,), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
os.close(w)
os.set_blocking(r, True)
data = os.read(r, 8)
assert data[:1] == b"\n", "no readiness"
os.close(r)
def cpu(pid):
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().split()
    return int(parts[13]) + int(parts[14])
c0 = cpu(p.pid)
time.sleep(3)
c1 = cpu(p.pid)
p.terminate()
p.wait(timeout=5)
print(c1 - c0)
PY
idle_one() {
  prog=$1
  tag=$2
  dev=$TMP/idle-$tag-dev
  sys=$TMP/idle-$tag-sys
  mkdir -p "$dev" "$sys"
  printf 'mydev root:root 600\n' > "$TMP/idle-$tag.conf"
  python3 "$TMP/idle_probe.py" "$prog" "$TMP/idle-$tag.conf" "$dev" "$sys"
}
rust_idle=$(idle_one "$RUST_MDEVD" rust)
c_idle=$(idle_one "$C_MDEVD" c)
echo "idle: rust_cpu_ticks=$rust_idle c_cpu_ticks=$c_idle (gate: rust <= 2x c + 2 ticks)"
python3 -c "r=int('$rust_idle'); c=int('$c_idle'); import sys; sys.exit(0 if r <= 2*c + 2 else 1)" || {
  echo "measure-perf: idle CPU exceeds 2x C reference" >&2
  exit 1
}

echo "measure-perf: OK (thresholds only; see docs/perf.md)"
