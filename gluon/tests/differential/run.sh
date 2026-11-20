#!/bin/bash
# Differential harness (P-6, P-7). Compares reference Meson/Ninja against
# gluon meson/ninja on fixture corpus.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DIFF_DIR="$ROOT/tests/differential"
FIX_DIR="$DIFF_DIR/fixtures"
LEDGER="$DIFF_DIR/expected-fail"
TMPBASE="$ROOT/.work/tmp/diff"
. "$DIFF_DIR/symbols.sh"
. "$DIFF_DIR/references.sh"
PIN_FILE="$ROOT/tests/upstream/PINS"
GLUON_MESON="$ROOT/target/release/meson"
GLUON_NINJA="$ROOT/target/release/ninja"

export LC_ALL=C
export TZ=UTC
export ZERO_AR_DATE=1
mkdir -p "$TMPBASE"

if [ ! -x "$GLUON_MESON" ] || [ ! -x "$GLUON_NINJA" ]; then
  echo "error: gluon bins missing; run cargo build --release first" >&2
  exit 1
fi
meson_pin=$(awk -F= '$1 == "MESON_VERSION" { print $2 }' "$PIN_FILE") || exit 1
ninja_pin=$(awk -F= '$1 == "NINJA_VERSION" { print $2 }' "$PIN_FILE") || exit 1
ref_meson=$(reference_tool meson "$GLUON_MESON" "$meson_pin") || exit 1
ref_ninja=$(reference_tool ninja "$GLUON_NINJA" "$ninja_pin") || exit 1
printf 'reference meson %s (%s), ninja %s (%s)\n' "$meson_pin" "$ref_meson" "$ninja_pin" "$ref_ninja"

if ! python3 "$DIFF_DIR/normalize.py" --selftest >/dev/null 2>&1; then
  echo "error: normalize selftest failed" >&2
  exit 1
fi
bash "$DIFF_DIR/test-symbols.sh" || exit 1

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

rm -rf "$TMPBASE"
mkdir -p "$TMPBASE"

require_idle_ninja() {
  local id=$1 ref_build=$2 cand_build=$3 work=$4
  local progress='gluon-parity-edge ' ref_noop cand_noop
  NINJA_STATUS="${progress}%f/%t " "$ref_ninja" -C "$ref_build" >"$work/noop.log" 2>&1
  ref_noop=$?
  NINJA_STATUS="${progress}%f/%t " "$GLUON_NINJA" -C "$cand_build" >"$work/cand_noop.log" 2>&1
  cand_noop=$?
  if [ "$ref_noop" != 0 ] || [ "$cand_noop" != 0 ]; then
    printf 'FAIL %s no-op exit ref=%s cand=%s\n' "$id" "$ref_noop" "$cand_noop" >>"$TMPBASE/results.log"
    return 1
  fi
  if grep -q "^$progress" "$work/noop.log" "$work/cand_noop.log"; then
    printf 'FAIL %s no-op ran a build edge\n' "$id" >>"$TMPBASE/results.log"
    return 1
  fi
  return 0
}

check_step_exit() {
  local id=$1 stage=$2 reference=$3 candidate=$4 expected=0
  local expectation="$FIX_DIR/$id/$stage-exit"
  if [ -f "$expectation" ]; then
    expected=$(cat "$expectation") || return 1
  fi
  if [ "$reference" != "$expected" ] || [ "$candidate" != "$expected" ]; then
    printf 'FAIL %s %s exit expected=%s ref=%s cand=%s\n' "$id" "$stage" "$expected" "$reference" "$candidate" >>"$TMPBASE/results.log"
    return 1
  fi
  return 0
}

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
    cp -R "$f" "$src_copy/"
  done
  ref_build="$work/build"
  cand_build="$cand_work/builddir"
  mkdir -p "$ref_build" "$cand_build"
  setup_args=()
  for setup_file in "$src/setup-args.txt" "$src/setup-args-$(uname -s).txt"; do
    [ -f "$setup_file" ] || continue
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      setup_args+=("$line")
    done <"$setup_file"
  done
  setup_env=()
  if [ -f "$src/setup-env.txt" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      setup_env+=("$line")
    done <"$src/setup-env.txt"
  fi
  setup_path=$PATH
  [ -d "$src_copy/bin" ] && setup_path="$src_copy/bin:$PATH"
  PATH=$setup_path env ${setup_env[@]+"${setup_env[@]}"} NINJA="$ref_ninja" "$ref_meson" setup "$ref_build" "$src_copy" ${setup_args[@]+"${setup_args[@]}"} >"$work/setup.log" 2>&1
  ref_setup=$?
  if grep -Fq ' (oxidized-meson)' "$work/setup.log"; then
    printf 'error: reference Meson identified itself as oxidized-meson: %s\n' "$ref_meson" >&2
    exit 1
  fi
  (cd "$cand_work" && PATH=$setup_path env ${setup_env[@]+"${setup_env[@]}"} "$GLUON_MESON" setup "$src_copy" ${setup_args[@]+"${setup_args[@]}"} >"$work/cand_setup.log" 2>&1)
  cand_setup=$?
  check_step_exit "$id" setup "$ref_setup" "$cand_setup" || return 1
  stray=$(cd "$cand_work" && ls -A | grep -vx builddir)
  if [ -n "$stray" ]; then
    printf 'FAIL %s setup wrote outside the build directory: %s\n' "$id" "$stray" >>"$TMPBASE/results.log"
    return 1
  fi
  if [ "$ref_setup" != "0" ]; then
    printf 'PASS %s expected setup failure (exit %s)\n' "$id" "$ref_setup" >>"$TMPBASE/results.log"
    return 0
  fi
  skip_edges=0
  if [ -f "$src/skip-edge-count" ]; then
    skip_edges=1
  fi
  "$ref_ninja" -C "$ref_build" >"$work/build.log" 2>&1
  ref_build_exit=$?
  "$GLUON_NINJA" -C "$cand_build" >"$work/cand_build.log" 2>&1
  cand_build_exit=$?
  check_step_exit "$id" build "$ref_build_exit" "$cand_build_exit" || return 1
  if [ "$ref_build_exit" != "0" ]; then
    printf 'PASS %s expected build failure (exit %s)\n' "$id" "$ref_build_exit" >>"$TMPBASE/results.log"
    return 0
  fi
  if [ -f "$src/expect-flags.txt" ]; then
    grep -E '^[[:space:]]*(LINK_)?ARGS = ' "$ref_build/build.ninja" >"$work/ref_args.txt" 2>/dev/null || true
    grep -E '^[[:space:]]*(LINK_)?ARGS = ' "$cand_build/build.ninja" >"$work/cand_args.txt" 2>/dev/null || true
    while IFS= read -r flag; do
      [ -z "$flag" ] && continue
      if ! grep -F -- "$flag" "$work/ref_args.txt" >/dev/null 2>&1; then
        printf 'FAIL %s reference ARGS missing %s\n' "$id" "$flag" >>"$TMPBASE/results.log"
        return 1
      fi
      if ! grep -F -- "$flag" "$work/cand_args.txt" >/dev/null 2>&1; then
        printf 'FAIL %s candidate ARGS missing %s\n' "$id" "$flag" >>"$TMPBASE/results.log"
        return 1
      fi
    done <"$src/expect-flags.txt"
  fi
  # compare executed edges (counts) and final artifacts (symbols); rule
  # definitions differ by design (P-6), so defined-command sets are not compared.
  # Final outputs: executables, shared libs, static libs (exclude intermediates).
  if [ "$skip_edges" -eq 0 ]; then
    ref_edges=$(grep -c '^\[[0-9]*\/' "$work/build.log" || true)
    cand_edges=$(grep -c '^\[[0-9]*\/' "$work/cand_build.log" || true)
    if [ "$ref_edges" != "$cand_edges" ]; then
      printf 'FAIL %s edge count ref=%s cand=%s\n' "$id" "$ref_edges" "$cand_edges" >>"$TMPBASE/results.log"
      return 1
    fi
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
    case $(file -b "$ref_build/$ref_path" 2>/dev/null) in
      *Mach-O*|*ELF*|*'current ar archive'*)
        if ! defined_symbols "$ref_build/$ref_path" >"$work/nm_ref.txt" 2>>"$work/nm_errors.log" ||
           ! defined_symbols "$cand_build/$cand_path" >"$work/nm_cand.txt" 2>>"$work/nm_errors.log"; then
          printf 'FAIL %s could not read symbols for %s\n' "$id" "$bn" >>"$TMPBASE/results.log"
          return 1
        fi
        if ! diff -q "$work/nm_ref.txt" "$work/nm_cand.txt" >/dev/null 2>&1; then
          printf 'FAIL %s symbols mismatch for %s\n' "$id" "$bn" >>"$TMPBASE/results.log"
          diff "$work/nm_ref.txt" "$work/nm_cand.txt" >>"$TMPBASE/results.log" || true
          return 1
        fi
        ;;
    esac
    i=$((i+1))
  done
  require_idle_ninja "$id" "$ref_build" "$cand_build" "$work" || return 1
  if [ -f "$src/compare-install" ]; then
    ref_dest="$work/dest"
    cand_dest="$cand_work/dest"
    rm -rf "$ref_dest" "$cand_dest"
    DESTDIR="$ref_dest" "$ref_ninja" -C "$ref_build" install >"$work/install.log" 2>&1
    ref_install=$?
    DESTDIR="$cand_dest" "$GLUON_NINJA" -C "$cand_build" install >"$work/cand_install.log" 2>&1
    cand_install=$?
    if [ "$ref_install" != "$cand_install" ]; then
      printf 'FAIL %s install exit ref=%s cand=%s\n' "$id" "$ref_install" "$cand_install" >>"$TMPBASE/results.log"
      return 1
    fi
    if [ "$ref_install" != "0" ]; then
      printf 'FAIL %s install failed (both exit %s)\n' "$id" "$ref_install" >>"$TMPBASE/results.log"
      return 1
    fi
    python3 "$DIFF_DIR/install_snapshot.py" "$ref_dest" >"$work/install_tree.txt"
    python3 "$DIFF_DIR/install_snapshot.py" "$cand_dest" >"$work/cand_install_tree.txt"
    if ! diff -q "$work/install_tree.txt" "$work/cand_install_tree.txt" >/dev/null 2>&1; then
      printf 'FAIL %s installed tree mismatch\n' "$id" >>"$TMPBASE/results.log"
      diff "$work/install_tree.txt" "$work/cand_install_tree.txt" >>"$TMPBASE/results.log" || true
      return 1
    fi
    if [ -f "$src/compare-install-ids" ]; then
      python3 "$DIFF_DIR/install_ids.py" "$ref_dest" >"$work/install_ids.txt"
      python3 "$DIFF_DIR/install_ids.py" "$cand_dest" >"$work/cand_install_ids.txt"
      if ! diff -q "$work/install_ids.txt" "$work/cand_install_ids.txt" >/dev/null 2>&1; then
        printf 'FAIL %s installed library ids mismatch\n' "$id" >>"$TMPBASE/results.log"
        diff "$work/install_ids.txt" "$work/cand_install_ids.txt" >>"$TMPBASE/results.log" || true
        return 1
      fi
    fi
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
  if [ -f "$src/prepare-target" ]; then
    local prepare_target ref_prepare cand_prepare
    prepare_target=$(cat "$src/prepare-target") || return 1
    "$ref_ninja" -C "$work" "$prepare_target" >"$work/prepare.log" 2>&1
    ref_prepare=$?
    "$GLUON_NINJA" -C "$cand_work" "$prepare_target" >"$work/cand_prepare.log" 2>&1
    cand_prepare=$?
    check_step_exit "$id" prepare "$ref_prepare" "$cand_prepare" || return 1
  fi
  "$ref_ninja" -C "$work" >"$work/build.log" 2>&1
  ref_build_exit=$?
  "$GLUON_NINJA" -C "$cand_work" >"$work/cand_build.log" 2>&1
  cand_build_exit=$?
  check_step_exit "$id" build "$ref_build_exit" "$cand_build_exit" || return 1
  if [ "$ref_build_exit" != "0" ]; then
    printf 'PASS %s expected build failure (exit %s)\n' "$id" "$ref_build_exit" >>"$TMPBASE/results.log"
    return 0
  fi
  (cd "$work" && find . -type f ! -name '.ninja_log' ! -name '.ninja_deps' ! -name '*.log' ! -name 'files*.txt' ! -name 'results.log' | LC_ALL=C sort >"$work/files.txt")
  (cd "$cand_work" && find . -type f ! -name '.ninja_log' ! -name '.ninja_deps' ! -name '*.log' ! -name 'files*.txt' ! -name 'results.log' | LC_ALL=C sort >"$work/cand_files.txt")
  if ! diff -q "$work/files.txt" "$work/cand_files.txt" >/dev/null 2>&1; then
    printf 'FAIL %s artifact list mismatch\n' "$id" >>"$TMPBASE/results.log"
    diff "$work/files.txt" "$work/cand_files.txt" >>"$TMPBASE/results.log" || true
    return 1
  fi
  local relative
  while IFS= read -r relative; do
    if ! cmp -s "$work/$relative" "$cand_work/$relative"; then
      printf 'FAIL %s artifact bytes differ for %s\n' "$id" "$relative" >>"$TMPBASE/results.log"
      return 1
    fi
  done <"$work/files.txt"
  require_idle_ninja "$id" "$work" "$cand_work" "$work" || return 1
  printf 'PASS %s\n' "$id" >>"$TMPBASE/results.log"
  return 0
}

: >"$TMPBASE/results.log"
overall=0

# meson fixtures
for d in $meson_dirs; do
  name=$(basename "$d")
  id="meson/$name"
  if [ -f "$d/requires-pkg-config" ]; then
    missing=''
    while IFS= read -r dependency; do
      if ! pkg-config --exists "$dependency" 2>/dev/null; then
        missing="$missing $dependency"
      fi
    done <"$d/requires-pkg-config"
    if [ -n "$missing" ]; then
      printf 'SKIP %s missing pkg-config dependencies:%s\n' "$id" "$missing" | tee -a "$TMPBASE/results.log"
      continue
    fi
  fi
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
