#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$root/.work/tmp"
scratch=$(mktemp -d "$root/.work/tmp/ninja-observables.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
diff_dir="$scratch/tests/differential"
mkdir -p "$scratch/bin" "$scratch/target/release" "$scratch/tests/upstream" \
  "$diff_dir/fixtures/meson" "$diff_dir/fixtures/ninja/one"
cp "$root/tests/differential/"{run,references,symbols,test-symbols}.sh "$diff_dir/"
cp "$root/tests/differential/normalize.py" "$diff_dir/"
cp "$root/tests/upstream/PINS" "$scratch/tests/upstream/"
export MESON_PIN NINJA_PIN
MESON_PIN=$(awk -F= '$1 == "MESON_VERSION" { print $2 }' "$scratch/tests/upstream/PINS")
NINJA_PIN=$(awk -F= '$1 == "NINJA_VERSION" { print $2 }' "$scratch/tests/upstream/PINS")
cat >"$scratch/bin/meson" <<'EOF'
#!/bin/sh
printf '%s\n' "$MESON_PIN"
EOF
printf '#!/bin/sh\nexit 7\n' >"$scratch/target/release/meson"
cat >"$scratch/bin/ninja" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then
  printf '%s\n' "$NINJA_PIN"
elif [ "$FAULT" = build-exit ]; then
  exit 7
elif [ ! -f "$2/out" ]; then
  printf 'fixture' >"$2/out"
fi
EOF
cat >"$scratch/target/release/ninja" <<'EOF'
#!/bin/sh
if [ "$FAULT" = build-exit ]; then exit 7; fi
if [ -f "$2/out" ]; then
  case "$FAULT" in
    rebuild) printf '%s\n' "$NINJA_STATUS" ;;
    exit) exit 7 ;;
  esac
else
  if [ "$FAULT" = bytes ]; then
    printf 'changed' >"$2/out"
  else
    printf 'fixture' >"$2/out"
  fi
fi
EOF
chmod +x "$scratch/bin/"* "$scratch/target/release/"*
export PATH="$scratch/bin:$PATH"
FAULT='' bash "$diff_dir/run.sh" >"$scratch/control.log" 2>&1 || {
  cat "$scratch/control.log" >&2
  exit 1
}

reject() {
  local fault=$1 diagnostic=$2
  if FAULT="$fault" bash "$diff_dir/run.sh" >"$scratch/control.log" 2>&1; then
    printf 'accepted Ninja fixture fault: %s\n' "$fault" >&2
    exit 1
  fi
  grep -Fq "$diagnostic" "$scratch/control.log" || {
    cat "$scratch/control.log" >&2
    exit 1
  }
}
reject bytes 'artifact bytes differ for ./out'
reject rebuild 'no-op ran a build edge'
reject exit 'no-op exit ref=0 cand=7'
reject build-exit 'build exit expected=0 ref=7 cand=7'
printf '7\n' >"$diff_dir/fixtures/ninja/one/build-exit"
reject '' 'build exit expected=7 ref=0 cand=0'
FAULT=build-exit bash "$diff_dir/run.sh" >"$scratch/control.log" 2>&1 || {
  cat "$scratch/control.log" >&2
  exit 1
}
grep -Fq 'PASS ninja/one expected build failure (exit 7)' "$scratch/.work/tmp/diff/results.log"
