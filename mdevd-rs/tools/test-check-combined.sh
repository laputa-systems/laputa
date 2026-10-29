#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$PWD
mkdir -p "$root/.work/tmp"
scratch=$(mktemp -d "$root/.work/tmp/check-combined.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/bin" "$scratch/libudev-zero" "$scratch/mdevd/tools" \
  "$scratch/mdevd/target/x86_64-unknown-linux-musl/release" \
  "$scratch/seatd-rs" "$scratch/doas-rs"
cp tools/check-combined.sh "$scratch/mdevd/tools/check-combined.sh"
cat > "$scratch/mdevd/target/x86_64-unknown-linux-musl/release/mdevd" <<'SCRIPT'
#!/bin/sh
echo reached > "$TEST_SCRATCH/stale-executed"
SCRIPT
chmod +x "$scratch/mdevd/target/x86_64-unknown-linux-musl/release/mdevd"
cat > "$scratch/bin/git" <<'SCRIPT'
#!/bin/sh
case "$*" in
  *status*) exit 0 ;;
  *rev-parse*) echo 8f1d3d0624496f1c4967f18d6afaddbd552d8bce ;;
esac
SCRIPT
cat > "$scratch/bin/cargo" <<'SCRIPT'
#!/bin/sh
count=0
[ ! -f "$TEST_SCRATCH/count" ] || count=$(cat "$TEST_SCRATCH/count")
count=$((count + 1))
echo "$count" > "$TEST_SCRATCH/count"
[ "$count" -ne "$FAIL_BUILD" ]
SCRIPT
cat > "$scratch/bin/sha256sum" <<'SCRIPT'
#!/bin/sh
"$1"
exit 0
SCRIPT
chmod +x "$scratch/bin/"*
for fail in 1 2 3; do
  rm -f "$scratch/count" "$scratch/stale-executed"
  if PATH="$scratch/bin:$PATH" TEST_SCRATCH="$scratch" FAIL_BUILD="$fail" \
    LIBUDEV_ZERO_SRC="$scratch/libudev-zero" /bin/sh "$scratch/mdevd/tools/check-combined.sh" > "$scratch/output" 2>&1; then
    echo "build $fail failure was ignored" >&2
    exit 1
  fi
  if [ -f "$scratch/stale-executed" ] || [ "$(cat "$scratch/count")" -ne "$fail" ]; then
    echo "build $fail failure did not stop the harness" >&2
    exit 1
  fi
done
echo 'check-combined build failures stop qualification'
