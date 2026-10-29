#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
script=${1:-$PWD/tools/check-udev-consumer.sh}
mkdir -p .work/tmp
scratch=$(mktemp -d "$PWD/.work/tmp/udev-status.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/tools" "$scratch/bin" "$scratch/reference" "$scratch/.work/tmp"
cp "$script" "$scratch/tools/check-udev-consumer.sh"
cat > "$scratch/bin/git" <<'STUB'
#!/bin/sh
printf '%s\n' 8f1d3d0624496f1c4967f18d6afaddbd552d8bce
STUB
cat > "$scratch/bin/cc" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$scratch/bin/unshare" <<'STUB'
#!/bin/sh
printf '%s\n' 'live-multicast: exchanged' 'live-consumer: verified'
exit "${TEST_CARGO_STATUS:?}"
STUB
chmod +x "$scratch/bin/"*
for status in 0 1; do
  if PATH="$scratch/bin:$PATH" LIBUDEV_ZERO_SRC="$scratch/reference" TEST_CARGO_STATUS=$status \
    /bin/sh "$scratch/tools/check-udev-consumer.sh" > "$scratch/output" 2>&1; then
    [ "$status" -eq 0 ] || { cat "$scratch/output"; exit 1; }
  else
    [ "$status" -ne 0 ] || { cat "$scratch/output"; exit 1; }
  fi
done
printf '%s\n' 'check-udev-consumer status regression passed'
