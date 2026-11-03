#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# == 1 ]] || { printf 'usage: run-ktest.sh CRATE_DIR_UNDER_ASTERINAS (for example ostd)\n' >&2; exit 2; }
crate_dir="$1"
source_dir="$repo_root/asterinas"
cache_dir="$repo_root/.cache/asterinas"
[[ -f "$source_dir/$crate_dir/Cargo.toml" ]] || { printf 'run-ktest: no crate at %s\n' "$source_dir/$crate_dir" >&2; exit 2; }
[[ -c /dev/kvm && -w /dev/kvm ]] || { printf 'run-ktest: /dev/kvm is not writable\n' >&2; exit 1; }
osdk_bin="$(ls -td "$cache_dir"/osdk/*/bin/cargo-osdk 2>/dev/null | head -n 1)"
[[ -x "$osdk_bin" ]] || { printf 'run-ktest: cargo-osdk is not installed; run make asterinas-build first\n' >&2; exit 1; }

dev_image="asterinas/dev:$(cat "$source_dir/DOCKER_IMAGE_VERSION")"
toolchain="$(rg -o 'nightly-[0-9-]+' "$source_dir/rust-toolchain.toml" | head -n 1)"
mkdir -p "$source_dir/test/initramfs/build"
for image in ext2 exfat ltp_dev nvme0n1; do
    [[ -e "$source_dir/test/initramfs/build/$image.img" ]] || truncate -s 8M "$source_dir/test/initramfs/build/$image.img"
done

export TMPDIR="$repo_root/.work/tmp"
mkdir -p "$TMPDIR"
output="$(mktemp)"
trap 'rm -f -- "$output"' EXIT
status=0
docker run --rm --pull never --platform linux/amd64 --network none --device /dev/kvm \
    --mount "type=bind,src=$source_dir,dst=/src/asterinas" \
    --mount "type=bind,src=$cache_dir,dst=/work/asterinas" \
    --mount "type=bind,src=$source_dir/.cargo/config.toml,dst=/work/asterinas/cargo/config.toml,readonly" \
    --workdir "/src/asterinas/$crate_dir" \
    --env CARGO_HOME=/work/asterinas/cargo --env CARGO_TARGET_DIR=/work/asterinas/target-ktest \
    --env CARGO_NET_OFFLINE=true --env KACHE_RUSTC_PATH_NORMALIZE=0 --env "CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-8}" \
    --env "RUSTUP_TOOLCHAIN=$toolchain" --env VDSO_LIBRARY_DIR=/root/linux_vdso \
    --env CONSOLE=ttyS0 --env MEM=2G --env SMP=2 --env ENABLE_KVM=1 \
    --entrypoint "/work/asterinas/osdk/$(basename "$(dirname "$(dirname "$osdk_bin")")")/bin/cargo-osdk" "$dev_image" \
    osdk test --target-arch=x86_64 > "$output" 2>&1 || status=$?
sed 's/\x1b\[[0-9;]*m//g' "$output" | tr -d '\r' | rg '^test |test result|ktest runner|panicked' || true
plain="$(sed 's/\x1b\[[0-9;]*m//g' "$output")"
if (( status != 0 )) || rg -q '^test result: FAILED' <<< "$plain" || ! rg -q '^test result: ok\. [1-9][0-9]* passed; 0 failed' <<< "$plain"; then
    printf 'run-ktest: %s kernel tests failed; tail follows\n' "$crate_dir" >&2
    tail -n 40 "$output" >&2
    exit 1
fi
