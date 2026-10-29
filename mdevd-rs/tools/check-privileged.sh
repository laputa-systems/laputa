#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
mkdir -p .work/tmp
export TMPDIR="$ROOT/.work/tmp"
artifacts=$(cargo test --locked --target x86_64-unknown-linux-musl --test adversarial --no-run --message-format json)
TEST_BIN=$(printf '%s\n' "$artifacts" | jaq -r 'select(.reason == "compiler-artifact" and .profile.test) | .executable // empty')
test -n "$TEST_BIN"
docker run --rm --pull never --network none --read-only \
  --cap-drop ALL --cap-add MKNOD --cap-add CHOWN --cap-add FOWNER \
  --security-opt no-new-privileges \
  --mount "type=bind,src=$ROOT,dst=$ROOT,readonly" \
  --tmpfs "$ROOT/.work/tmp:rw,nosuid,nodev,size=64m" \
  --workdir "$ROOT" --entrypoint "$TEST_BIN" ubuntu:24.04 \
  devices:: --ignored --test-threads=1 --nocapture

docker run --rm --pull never --network none --read-only \
  --cap-drop ALL --cap-add NET_ADMIN \
  --security-opt no-new-privileges \
  --mount "type=bind,src=$ROOT,dst=$ROOT,readonly" \
  --mount type=bind,src=/bin/busybox,dst=/busybox,readonly \
  --mount type=bind,src=/lib/ld-musl-x86_64.so.1,dst=/lib/ld-musl-x86_64.so.1,readonly \
  --tmpfs "$ROOT/.work/tmp:rw,nosuid,nodev,size=64m" \
  --workdir "$ROOT" --entrypoint "$TEST_BIN" ubuntu:24.04 \
  kernel:: --ignored --test-threads=1 --nocapture
