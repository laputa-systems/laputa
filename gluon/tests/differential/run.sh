#!/bin/bash
# Differential harness (P-6, P-7). Compares reference Meson/Ninja against
# gluon meson/ninja on fixture corpus.
# Success: exit 0 only if every fixture parity matches or is ledgered in
# expected-fail, and no ledgered fixture now passes. Identical over 3 repeats.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DIFF_DIR="$ROOT/tests/differential"
FIX_DIR="$DIFF_DIR/fixtures"
LEDGER="$DIFF_DIR/expected-fail"
TMPBASE="$ROOT/.work/tmp/diff"
GLUON_MESON="$ROOT/target/release/meson"
GLUON_NINJA="$ROOT/target/release/ninja"

export LC_ALL=C
export TZ=UTC
export ZERO_AR_DATE=1
mkdir -p "$TMPBASE"

# selftest normalization rules (P-6)
if ! python3 "$DIFF_DIR/normalize.py" --selftest >/dev/null 2>&1; then
  echo "error: normalize selftest failed" >&2
  exit 1
fi

# verify pins (P-3)
ref_meson=$(meson --version 2>&1 | head -1)
ref_ninja=$(ninja --version 2>&1 | head -1)
ref_muon=$(muon version 2>&1 | head -1)
if [ "$ref_meson" != "1.12.1" ]; then
  echo "warning: expected meson 1.12.1, found $ref_meson" >&2
fi
if [ "$ref_ninja" != "1.13.2" ]; then
  echo "warning: expected ninja 1.13.2, found $ref_ninja" >&2
fi
case "$ref_muon" in
  *0.7.0*) : ;;
  *) echo "warning: expected muon 0.7.0, found $ref_muon" >&2 ;;
esac

if [ ! -x "$GLUON_MESON" ] || [ ! -x "$GLUON_NINJA" ]; then
  echo "error: gluon bins missing; run cargo build --release first" >&2
  exit 1
fi
gluon_meson_ver=$("$GLUON_MESON" --version 2>&1 | head -1)
gluon_ninja_ver=$("$GLUON_NINJA" --version 2>&1 | head -1)
echo "reference meson $ref_meson ninja $ref_ninja; gluon meson $gluon_meson_ver ninja $gluon_ninja_ver"

# helper: ledger lookup (bash 3.2 compatible, no assoc arrays)
ledger_has() {
  # $1 = id like meson/trivial
  if [ ! -f "$LEDGER" ]; then
    return 1
  fi
  # ignore comments/blank; match exact id at line start before ' :'
  if grep -E "^[[:space:]]*$1[[:space:]]*:" "$LEDGER" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
ledger_cause() {
  # $1 = id
  if [ -f "$LEDGER" ]; then
    grep -E "^[[:space:]]*$1[[:space:]]*:" "$LEDGER" | head -1 | sed 's/^[^:]*: *//'
  fi
}

# discover fixtures deterministically
# list dirs sorted
meson_dirs=$(find "$FIX_DIR/meson" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
ninja_dirs=$(find "$FIX_DIR/ninja" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

# clean temp base for repeatability (identical over 3 repeats)
rm -rf "$TMPBASE"
mkdir -p "$TMPBASE"

run_compare_meson() {
  id=$1
  name=$2
  src="$FIX_DIR/meson/$name"
  work="$TMPBASE/$id/ref"
  cand_work="$TMPBASE/$id/cand"
  src_copy="$TMPBASE/$id/src"
  rm -rf "$work" "$cand_work" "$src_copy"
  mkdir -p "$work" "$cand_work" "$src_copy"
  # copy all src files
  for f in "$src"/*; do
    [ -e "$f" ] || continue
    cp "$f" "$src_copy/"
  done
  ref_build="$work/build"
  cand_build="$cand_work/builddir"
  mkdir -p "$ref_build" "$cand_build"
  meson setup "$ref_build" "$src_copy" >"$work/setup.log" 2>&1
  ref_setup=$?
  (cd "$cand_work" && "$GLUON_MESON" setup "$src_copy" >"$work/cand_setup.log" 2>&1)
  cand_setup=$?
  if [ "$ref_setup" != "$cand_setup" ]; then
    printf 'FAIL %s setup exit ref=%s cand=%s\n' "$id" "$ref_setup" "$cand_setup" >>"$TMPBASE/results.log"
    return 1
  fi
  if [ "$ref_setup" != "0" ]; then
    printf 'PASS %s setup-both-fail (both exit %s)\n' "$id" "$ref_setup" >>"$TMPBASE/results.log"
    return 0
  fi
  ninja -C "$ref_build" >"$work/build.log" 2>&1
  ref_build_exit=$?
  "$GLUON_NINJA" -C "$cand_build" >"$work/cand_build.log" 2>&1
  cand_build_exit=$?
  if [ "$ref_build_exit" != "$cand_build_exit" ]; then
    printf 'FAIL %s build exit ref=%s cand=%s\n' "$id" "$ref_build_exit" "$cand_build_exit" >>"$TMPBASE/results.log"
    return 1
  fi
  if [ "$ref_build_exit" != "0" ]; then
    printf 'PASS %s build-both-fail (both exit %s)\n' "$id" "$ref_build_exit" >>"$TMPBASE/results.log"
    return 0
  fi
  # compare executed edges (counts) and final artifacts (symbols); rule
  # definitions differ by design (P-6), so defined-command sets are not compared.
  # Final outputs: executables, shared libs, static libs (exclude intermediates).
  ref_edges=$(grep -c '^\[[0-9]*\/' "$work/build.log" || true)
  cand_edges=$(grep -c '^\[[0-9]*\/' "$work/cand_build.log" || true)
  if [ "$ref_edges" != "$cand_edges" ]; then
    printf 'FAIL %s edge count ref=%s cand=%s\n' "$id" "$ref_edges" "$cand_edges" >>"$TMPBASE/results.log"
    return 1
  fi
  # find final outputs (exclude .o, .d, build.ninja, meson-info/logs/private,
  # compile_commands.json, ninja logs)
  (cd "$ref_build" && find . -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' -o -name '*.a' \) ! -name 'sanity_check*' ! -path './meson-*' | LC_ALL=C sort >"$work/final.txt")
  (cd "$cand_build" && find . -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' -o -name '*.a' \) ! -name 'sanity_check*' ! -path './meson-*' | LC_ALL=C sort >"$work/cand_final.txt")
  # meson installs no executables besides targets; if both empty, compare .o existence count
  if [ ! -s "$work/final.txt" ] && [ ! -s "$work/cand_final.txt" ]; then
    (cd "$ref_build" && find . -type f -name '*.o' | LC_ALL=C sort >"$work/final.txt")
    (cd "$cand_build" && find . -type f -name '*.o' | LC_ALL=C sort >"$work/cand_final.txt")
  fi
  # compare basenames (object dir layout differs by design: hello.p/ vs flat)
  sort -t/ -k2 "$work/final.txt" | xargs -n1 basename 2>/dev/null | LC_ALL=C sort >"$work/final_base.txt" || true
  sort -t/ -k2 "$work/cand_final.txt" | xargs -n1 basename 2>/dev/null | LC_ALL=C sort >"$work/cand_final_base.txt" || true
  if ! diff -q "$work/final_base.txt" "$work/cand_final_base.txt" >/dev/null 2>&1; then
    printf 'FAIL %s final artifact mismatch\n' "$id" >>"$TMPBASE/results.log"
    diff "$work/final_base.txt" "$work/cand_final_base.txt" >>"$TMPBASE/results.log" || true
    return 1
  fi
  # symbol comparison for each final output (basename match)
  nl=$(wc -l <"$work/final_base.txt" | tr -d ' ')
  i=1
  while [ $i -le $nl ]; do
    bn=$(sed -n "${i}p" "$work/final_base.txt")
    ref_path=$(cd "$ref_build" && find . -type f -name "$bn" | head -1)
    cand_path=$(cd "$cand_build" && find . -type f -name "$bn" | head -1)
    # only compare Mach-O binaries via nm symbols (strip addresses)
    if file "$ref_build/$ref_path" 2>/dev/null | grep -q 'Mach-O'; then
      nm "$ref_build/$ref_path" 2>/dev/null | awk '{print $NF}' | LC_ALL=C sort >"$work/nm_ref.txt" || true
      nm "$cand_build/$cand_path" 2>/dev/null | awk '{print $NF}' | LC_ALL=C sort >"$work/nm_cand.txt" || true
      if ! diff -q "$work/nm_ref.txt" "$work/nm_cand.txt" >/dev/null 2>&1; then
        printf 'FAIL %s symbols mismatch for %s\n' "$id" "$bn" >>"$TMPBASE/results.log"
        diff "$work/nm_ref.txt" "$work/nm_cand.txt" >>"$TMPBASE/results.log" || true
        return 1
      fi
    fi
    i=$((i+1))
  done
  ninja -C "$ref_build" >"$work/noop.log" 2>&1
  ref_noop=$?
  "$GLUON_NINJA" -C "$cand_build" >"$work/cand_noop.log" 2>&1
  cand_noop=$?
  if [ "$ref_noop" != "$cand_noop" ]; then
    printf 'FAIL %s no-op exit ref=%s cand=%s\n' "$id" "$ref_noop" "$cand_noop" >>"$TMPBASE/results.log"
    return 1
  fi
  ref_edges=$(grep -c '^\[[0-9]*\/' "$work/build.log" || true)
  cand_edges=$(grep -c '^\[[0-9]*\/' "$work/cand_build.log" || true)
  if [ "$ref_edges" != "$cand_edges" ]; then
    printf 'FAIL %s edge count ref=%s cand=%s\n' "$id" "$ref_edges" "$cand_edges" >>"$TMPBASE/results.log"
    return 1
  fi
  printf 'PASS %s\n' "$id" >>"$TMPBASE/results.log"
  return 0
}

run_compare_ninja() {
  id=$1
  name=$2
  src="$FIX_DIR/ninja/$name"
  work="$TMPBASE/$id/ref"
  cand_work="$TMPBASE/$id/cand"
  rm -rf "$work" "$cand_work"
  mkdir -p "$work" "$cand_work"
  for f in "$src"/*; do
    [ -e "$f" ] || continue
    cp "$f" "$work/"
    cp "$f" "$cand_work/"
  done
  ninja -C "$work" >"$work/build.log" 2>&1
  ref_build_exit=$?
  "$GLUON_NINJA" -C "$cand_work" >"$work/cand_build.log" 2>&1
  cand_build_exit=$?
  if [ "$ref_build_exit" != "$cand_build_exit" ]; then
    printf 'FAIL %s build exit ref=%s cand=%s\n' "$id" "$ref_build_exit" "$cand_build_exit" >>"$TMPBASE/results.log"
    return 1
  fi
  if [ "$ref_build_exit" != "0" ]; then
    printf 'PASS %s build-both-fail (both exit %s)\n' "$id" "$ref_build_exit" >>"$TMPBASE/results.log"
    return 0
  fi
  (cd "$work" && find . -type f ! -name '.ninja_log' ! -name '.ninja_deps' ! -name '*.log' ! -name 'files*.txt' ! -name 'results.log' | LC_ALL=C sort >"$work/files.txt")
  (cd "$cand_work" && find . -type f ! -name '.ninja_log' ! -name '.ninja_deps' ! -name '*.log' ! -name 'files*.txt' ! -name 'results.log' | LC_ALL=C sort >"$work/cand_files.txt")
  if ! diff -q "$work/files.txt" "$work/cand_files.txt" >/dev/null 2>&1; then
    printf 'FAIL %s artifact list mismatch\n' "$id" >>"$TMPBASE/results.log"
    diff "$work/files.txt" "$work/cand_files.txt" >>"$TMPBASE/results.log" || true
    return 1
  fi
  ninja -C "$work" >"$work/noop.log" 2>&1
  ref_noop=$?
  "$GLUON_NINJA" -C "$cand_work" >"$work/cand_noop.log" 2>&1
  cand_noop=$?
  if [ "$ref_noop" != "$cand_noop" ]; then
    printf 'FAIL %s no-op exit ref=%s cand=%s\n' "$id" "$ref_noop" "$cand_noop" >>"$TMPBASE/results.log"
    return 1
  fi
  printf 'PASS %s\n' "$id" >>"$TMPBASE/results.log"
  return 0
}

: >"$TMPBASE/results.log"
overall=0

# meson fixtures
for d in $meson_dirs; do
  name=$(basename "$d")
  id="meson/$name"
  if run_compare_meson "$id" "$name"; then
    result=pass
  else
    result=fail
  fi
  if [ "$result" = "pass" ] && ledger_has "$id"; then
    echo "STALE ledger entry now passes: $id : $(ledger_cause "$id")"
    overall=1
  elif [ "$result" = "fail" ] && ledger_has "$id"; then
    echo "EXPECTED-FAIL $id : $(ledger_cause "$id")"
  elif [ "$result" = "fail" ]; then
    echo "FAIL $id (unledgered mismatch, see $TMPBASE/results.log)"
    overall=1
  else
    echo "PASS $id"
  fi
done

for d in $ninja_dirs; do
  name=$(basename "$d")
  id="ninja/$name"
  if run_compare_ninja "$id" "$name"; then
    result=pass
  else
    result=fail
  fi
  if [ "$result" = "pass" ] && ledger_has "$id"; then
    echo "STALE ledger entry now passes: $id : $(ledger_cause "$id")"
    overall=1
  elif [ "$result" = "fail" ] && ledger_has "$id"; then
    echo "EXPECTED-FAIL $id : $(ledger_cause "$id")"
  elif [ "$result" = "fail" ]; then
    echo "FAIL $id (unledgered mismatch, see $TMPBASE/results.log)"
    overall=1
  else
    echo "PASS $id"
  fi
done

# ledgered ids must correspond to known fixtures
if [ -f "$LEDGER" ]; then
  while IFS= read -r line; do
    line_trim=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line_trim" ] && continue
    case "$line_trim" in \#*) continue ;; esac
    lid=$(printf '%s' "$line_trim" | sed 's/ :.*$//;s/[[:space:]]*$//')
    [ -z "$lid" ] && continue
    if [ ! -d "$FIX_DIR/$lid" ]; then
      echo "STALE ledger entry for unknown fixture: $lid"
      overall=1
    fi
  done < "$LEDGER"
fi

cat "$TMPBASE/results.log" | tail -n 50 || true
if [ $overall != 0 ]; then
  echo "differential harness: FAIL"
  exit 1
fi
echo "differential harness: PASS (ledger honored)"
exit 0
