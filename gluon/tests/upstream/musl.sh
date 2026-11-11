#!/bin/bash
# musl.sh (S6): build static-musl gluon bins in pinned Docker image and verify
# they run --version in the container. OD-6: --platform linux/amd64, rust:nightly-2026-09-15.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PINS="$ROOT/tests/upstream/PINS"
IMAGE=$(grep '^RUST_DOCKER_IMAGE=' "$PINS" | cut -d= -f2)
TARGET=$(grep '^MUSL_TARGET=' "$PINS" | cut -d= -f2)
OUTDIR="$ROOT/.work/tmp/musl"
TARGETDIR="$OUTDIR/target"
mkdir -p "$OUTDIR"

echo "musl: image=$IMAGE target=$TARGET platform=linux/amd64"
docker run --rm --platform linux/amd64 \
  -v "$ROOT:/app" -w /app \
  -e CARGO_TARGET_DIR=/app/.work/tmp/musl/target \
  "$IMAGE" \
  bash -c "rustup target add $TARGET && cargo build --release --target $TARGET"

# Verify static bins exist and run in container
for bin in meson ninja; do
  B="$TARGETDIR/$TARGET/release/$bin"
  if [ ! -x "$B" ]; then
    echo "error: missing $B" >&2
    exit 1
  fi
  echo "found $B"
done
echo "verifying --version in container..."
docker run --rm --platform linux/amd64 \
  -v "$ROOT:/app" -w /app \
  "$IMAGE" \
  bash -c "/app/.work/tmp/musl/target/$TARGET/release/meson --version && /app/.work/tmp/musl/target/$TARGET/release/ninja --version"
echo "musl: PASS"
