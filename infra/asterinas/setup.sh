#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
mode="${1:-setup}"
[[ "$mode" == setup || "$mode" == fetch || "$mode" == build ]] || {
    printf 'usage: %s [setup|fetch|build]\n' "$0" >&2
    exit 2
}
input_lock="$repo_root/infra/asterinas/inputs.lock"
[[ -f "$input_lock" ]] || {
    printf 'asterinas-setup: pinned input lock is missing: %s\n' "$input_lock" >&2
    exit 1
}
source "$input_lock"
cache_dir="$repo_root/.cache/asterinas"
output_dir="$repo_root/.out/asterinas-firecracker"
source_dir="$repo_root/asterinas"
target_dir="$cache_dir/target"
cargo_home="$cache_dir/cargo"
osdk_output_dir="$cache_dir/osdk-output"
initramfs_root="$cache_dir/initramfs/root"
firecracker_bin="$output_dir/bin/firecracker"
firecracker_pid=""
scratch_dir=""
logs_initialized=false

fail() {
    printf 'asterinas-setup: %s\n' "$*" >&2
    if [[ "$logs_initialized" == true && -s "$output_dir/smoke-console.log" ]]; then
        printf '\n--- Firecracker guest console ---\n' >&2
        tail -n 60 "$output_dir/smoke-console.log" >&2 || true
    fi
    if [[ "$logs_initialized" == true && -s "$output_dir/smoke-firecracker.log" ]]; then
        printf '\n--- Firecracker diagnostics ---\n' >&2
        tail -n 60 "$output_dir/smoke-firecracker.log" >&2 || true
    fi
    exit 1
}

stop_firecracker() {
    [[ -n "$firecracker_pid" ]] || return 0

    if kill -0 "$firecracker_pid" 2>/dev/null; then
        kill -TERM "$firecracker_pid" 2>/dev/null || true
        for _ in {1..50}; do
            local state
            state="$(ps -o stat= -p "$firecracker_pid" 2>/dev/null | tr -d ' ' || true)"
            [[ -z "$state" || "$state" == Z* ]] && break
            sleep 0.1
        done
        state="$(ps -o stat= -p "$firecracker_pid" 2>/dev/null | tr -d ' ' || true)"
        if [[ -n "$state" && "$state" != Z* ]]; then
            kill -KILL "$firecracker_pid" 2>/dev/null || true
        fi
    fi

    wait "$firecracker_pid" 2>/dev/null || true
    firecracker_pid=""
}

cleanup() {
    stop_firecracker
    if [[ -n "$scratch_dir" ]]; then
        rm -rf "$scratch_dir"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

need_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "required host command is missing: $1"
}

asterinas_source_hash() {
    git -C "$source_dir" ls-files --cached --others --exclude-standard -z | \
        docker run --rm --interactive --pull never --platform linux/amd64 --network none \
            --mount "type=bind,src=$source_dir,dst=/src/asterinas,readonly" \
            --entrypoint /usr/bin/tar "$dev_image_id" \
            --create --file=- --directory=/src/asterinas --null --files-from=- \
            --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner | \
        sha256sum | awk '{print $1}'
}

[[ "$(uname -s)" == Linux ]] || fail 'Firecracker setup requires a Linux host'
host_arch="$(uname -m)"
[[ "$host_arch" == x86_64 ]] || fail "Firecracker setup requires x86_64, found $host_arch"
if [[ "$mode" == setup ]]; then
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || fail '/dev/kvm must exist and be readable and writable by this user'
fi

for tool in awk cat chmod cp curl docker find git grep head mkdir mktemp mv ps readelf rm sha256sum sleep sort tail tar tee tr uname; do
    need_tool "$tool"
done

mkdir -p "$cache_dir" "$output_dir/bin" "$output_dir/logs"
: > "$output_dir/smoke-console.log"
: > "$output_dir/smoke-firecracker.log"
logs_initialized=true
docker info >/dev/null 2>&1 || fail 'Docker is unavailable to this user'
scratch_dir="$(mktemp -d "$cache_dir/setup.XXXXXX")"

[[ "$ASTERINAS_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'Asterinas commit pin must be a full Git commit id'
[[ "$ASTERINAS_DEV_IMAGE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'invalid pinned Asterinas dev image version'
[[ "$ASTERINAS_DEV_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'Asterinas dev image pin must be a SHA-256 digest'
[[ "$FIRECRACKER_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'invalid pinned Firecracker version'
[[ "$FIRECRACKER_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'Firecracker binary pin must be a SHA-256 digest'
git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1 || \
    fail "Asterinas submodule is not initialized: $source_dir; run make asterinas-fetch"
source_remote="$(git -C "$source_dir" remote get-url origin)"
[[ "$source_remote" == "$ASTERINAS_REPOSITORY" || \
   "$source_remote" == git@github.com:joshuarli/asterinas.git ]] || \
    fail "Asterinas submodule origin differs from the fork pin: $source_remote"
asterinas_commit="$ASTERINAS_COMMIT"
[[ "$asterinas_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'Asterinas commit pin must be a full Git commit id'
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$ASTERINAS_COMMIT" ]] || fail 'checked-out Asterinas source does not match its pin'
submodule_commit="$(git -C "$repo_root" ls-files --stage -- asterinas | awk '$4 == "asterinas" { print $2 }')"
[[ "$submodule_commit" == "$ASTERINAS_COMMIT" ]] || \
    fail 'Asterinas gitlink differs from inputs.lock; update inputs.lock and the gitlink together'
source_changes="$(git -C "$source_dir" status --porcelain --untracked-files=normal)"
if [[ -n "$source_changes" && "${ASTERINAS_LOCAL:-0}" != 1 ]]; then
    fail 'Asterinas source has local changes; use ASTERINAS_LOCAL=1 for a fingerprinted developer build'
fi
[[ "${ASTERINAS_LOCAL:-0}" == 0 || "${ASTERINAS_LOCAL:-0}" == 1 ]] || \
    fail 'ASTERINAS_LOCAL must be 0 or 1'
source_state=clean
if [[ -n "$source_changes" ]]; then
    source_state=working-tree
fi
toolchain_channel="$(sed -n 's/^channel[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$source_dir/rust-toolchain.toml")"
[[ -n "$toolchain_channel" ]] || fail 'Asterinas Rust toolchain pin is missing'

dev_version="$ASTERINAS_DEV_IMAGE_VERSION"
[[ "$(cat "$source_dir/DOCKER_IMAGE_VERSION")" == "$dev_version" ]] || \
    fail "pinned Asterinas source expects dev image $(cat "$source_dir/DOCKER_IMAGE_VERSION"), lock selects $dev_version"
dev_image="asterinas/dev:$dev_version"
cached_dev_image_digest="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$dev_image" 2>/dev/null || true)"
if [[ "$cached_dev_image_digest" != "asterinas/dev@$ASTERINAS_DEV_IMAGE_DIGEST" ]]; then
    docker pull --platform linux/amd64 "$dev_image" 2>&1 | tee "$output_dir/logs/dev-image-pull.log"
fi
dev_image_id="$(docker image inspect --format '{{.Id}}' "$dev_image")"
dev_image_digest="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$dev_image")"
[[ "$dev_image_digest" == "asterinas/dev@$ASTERINAS_DEV_IMAGE_DIGEST" ]] || \
    fail "Asterinas dev image digest mismatch: expected asterinas/dev@$ASTERINAS_DEV_IMAGE_DIGEST, found $dev_image_digest"
toolchain_sysroot="$(docker run --rm --platform linux/amd64 --network none \
    --env RUSTUP_TOOLCHAIN="$toolchain_channel" \
    --entrypoint /usr/bin/env "$dev_image_id" rustc --print sysroot)"
sysroot_manifest="$toolchain_sysroot/lib/rustlib/src/rust/library/sysroot/Cargo.toml"
sysroot_lock="$toolchain_sysroot/lib/rustlib/src/rust/library/Cargo.lock"
source_snapshot_hash="$(asterinas_source_hash)"
[[ "$source_snapshot_hash" =~ ^[0-9a-f]{64}$ ]] || fail 'could not fingerprint Asterinas source'
toolchain_cargo_version="$(docker run --rm --platform linux/amd64 --network none --entrypoint /usr/bin/env "$dev_image_id" cargo --version)"
toolchain_rustc_version="$(docker run --rm --platform linux/amd64 --network none --entrypoint /usr/bin/env "$dev_image_id" rustc --version)"
toolchain_gcc_version="$(docker run --rm --platform linux/amd64 --network none --entrypoint /usr/bin/env "$dev_image_id" gcc --version | head -n 1)"
printf '%s\n%s\n%s\n' "$toolchain_cargo_version" "$toolchain_rustc_version" "$toolchain_gcc_version"
docker run --rm --platform linux/amd64 --network none --entrypoint /usr/bin/env "$dev_image_id" cpio --version
docker run --rm --platform linux/amd64 --network none --entrypoint /usr/bin/env "$dev_image_id" gzip --version
docker run --rm --platform linux/amd64 --network none --entrypoint /usr/bin/env "$dev_image_id" jq --version
docker run --rm --platform linux/amd64 --network none --entrypoint /usr/bin/test "$dev_image_id" -d /root/linux_vdso

sysroot_lock_hash="$(docker run --rm --platform linux/amd64 --network none \
    --entrypoint /usr/bin/sha256sum "$dev_image_id" "$sysroot_lock" | awk '{print $1}')"
cargo_lock_hash="$(printf '%s\n%s\n%s\n%s\n' \
    "$(sha256sum "$source_dir/Cargo.lock" "$source_dir/osdk/Cargo.lock" | sha256sum | awk '{print $1}')" \
    "$sysroot_lock_hash" "$toolchain_channel" "$dev_image_digest" | sha256sum | awk '{print $1}')"
cargo_lock_stamp="$cache_dir/cargo.lock.sha256"
mkdir -p "$cargo_home" "$target_dir" "$osdk_output_dir"
if [[ "$mode" == fetch || "$mode" == setup ]]; then
    docker run --rm --platform linux/amd64 \
        --mount "type=bind,src=$source_dir,dst=/src/asterinas,readonly" \
        --mount "type=bind,src=$cache_dir,dst=/work/asterinas" \
        --workdir /src/asterinas \
        --env CARGO_HOME=/work/asterinas/cargo \
        --env RUSTUP_TOOLCHAIN="$toolchain_channel" \
        --entrypoint /usr/bin/env "$dev_image_id" cargo fetch --locked
    docker run --rm --platform linux/amd64 \
        --mount "type=bind,src=$source_dir,dst=/src/asterinas,readonly" \
        --mount "type=bind,src=$cache_dir,dst=/work/asterinas" \
        --workdir /src/asterinas \
        --env CARGO_HOME=/work/asterinas/cargo \
        --env RUSTUP_TOOLCHAIN="$toolchain_channel" \
        --entrypoint /usr/bin/env "$dev_image_id" \
        cargo fetch --locked --manifest-path osdk/Cargo.toml
    docker run --rm --platform linux/amd64 \
        --mount "type=bind,src=$cache_dir,dst=/work/asterinas" \
        --env CARGO_HOME=/work/asterinas/cargo \
        --env RUSTUP_TOOLCHAIN="$toolchain_channel" \
        --entrypoint /usr/bin/env "$dev_image_id" \
        cargo fetch --locked --manifest-path "$sysroot_manifest"
    docker run --rm --platform linux/amd64 --network none \
        --mount "type=bind,src=$repo_root,dst=/src/laputa,readonly" \
        --mount "type=bind,src=$source_dir,dst=/src/asterinas,readonly" \
        --mount "type=bind,src=$cache_dir,dst=/work/asterinas" \
        --workdir /src/laputa \
        --env CARGO_HOME=/work/asterinas/cargo \
        --entrypoint /usr/bin/env "$dev_image_id" \
        bash infra/asterinas/seed-cargo-git-tags.sh \
        /src/asterinas/Cargo.lock /src/asterinas/osdk/Cargo.lock
    printf '%s\n' "$cargo_lock_hash" > "$cargo_lock_stamp.tmp"
    mv -f "$cargo_lock_stamp.tmp" "$cargo_lock_stamp"
elif [[ "$(cat "$cargo_lock_stamp" 2>/dev/null || true)" != "$cargo_lock_hash" ]]; then
    fail 'Asterinas Cargo inputs are not fetched for this lockfile; run make asterinas-fetch'
fi

firecracker_version="$FIRECRACKER_VERSION"

installed_firecracker_hash=""
if [[ -x "$firecracker_bin" && -f "$output_dir/firecracker.version" && -f "$output_dir/firecracker.sha256" ]]; then
    installed_firecracker_hash="$(sha256sum "$firecracker_bin" | awk '{print $1}')"
fi
if [[ "$(cat "$output_dir/firecracker.version" 2>/dev/null || true)" == "$firecracker_version" && \
      "$installed_firecracker_hash" == "$FIRECRACKER_BINARY_SHA256" && \
      "$installed_firecracker_hash" == "$(cat "$output_dir/firecracker.sha256" 2>/dev/null || true)" ]]; then
    "$firecracker_bin" --version | grep -Fq "$firecracker_version" || \
        fail "installed Firecracker does not report $firecracker_version"
    printf 'Firecracker %s is already installed.\n' "$firecracker_version"
else
    archive_name="firecracker-${firecracker_version}-x86_64.tgz"
    archive_path="$scratch_dir/$archive_name"
    checksum_path="$scratch_dir/$archive_name.sha256.txt"
    release_base="https://github.com/firecracker-microvm/firecracker/releases/download/$firecracker_version"
    curl --retry 3 --fail --location --silent --show-error \
        "$release_base/$archive_name" --output "$archive_path"
    curl --retry 3 --fail --location --silent --show-error \
        "$release_base/$archive_name.sha256.txt" --output "$checksum_path"
    expected_archive_hash="$(awk 'NR == 1 { print $1 }' "$checksum_path")"
    expected_archive_name="$(awk 'NR == 1 { sub(/^\*/, "", $2); print $2 }' "$checksum_path")"
    [[ "$expected_archive_hash" =~ ^[0-9a-f]{64}$ && "$expected_archive_name" == "$archive_name" ]] || \
        fail "invalid checksum file for $archive_name"
    actual_archive_hash="$(sha256sum "$archive_path" | awk '{print $1}')"
    [[ "$actual_archive_hash" == "$expected_archive_hash" ]] || \
        fail "Firecracker archive checksum mismatch for $firecracker_version"
    mkdir "$scratch_dir/firecracker"
    tar -xzf "$archive_path" -C "$scratch_dir/firecracker"
    candidate="$(find "$scratch_dir/firecracker" -type f -name "firecracker-${firecracker_version}-x86_64" -print -quit)"
    [[ -n "$candidate" ]] || fail "Firecracker archive did not contain the expected x86_64 executable"
    "$candidate" --version | grep -Fq "$firecracker_version" || \
        fail "downloaded Firecracker binary does not report $firecracker_version"
    install_tmp="$firecracker_bin.tmp.$$"
    cp "$candidate" "$install_tmp"
    chmod 755 "$install_tmp"
    binary_hash="$(sha256sum "$install_tmp" | awk '{print $1}')"
    [[ "$binary_hash" == "$FIRECRACKER_BINARY_SHA256" ]] || \
        fail "Firecracker binary checksum mismatch for $firecracker_version: expected $FIRECRACKER_BINARY_SHA256, found $binary_hash"
    mv -f "$install_tmp" "$firecracker_bin"
    printf '%s\n' "$firecracker_version" > "$output_dir/firecracker.version.tmp"
    mv -f "$output_dir/firecracker.version.tmp" "$output_dir/firecracker.version"
    firecracker_hash="$binary_hash"
    printf '%s\n' "$firecracker_hash" > "$output_dir/firecracker.sha256.tmp"
    mv -f "$output_dir/firecracker.sha256.tmp" "$output_dir/firecracker.sha256"
    printf 'Installed Firecracker %s at %s.\n' "$firecracker_version" "$firecracker_bin"
fi

if [[ "$mode" == fetch ]]; then
    printf 'Fetched pinned Asterinas Cargo inputs, dev image, and Firecracker %s.\n' "$firecracker_version"
    exit 0
fi

mkdir -p "$initramfs_root/bin" "$initramfs_root/dev" "$initramfs_root/proc" "$initramfs_root/sys"
cat > "$cache_dir/smoke-init.S" <<'INIT'
.section .rodata
marker:
.ascii "ASTERINAS_PVH_BOOT_OK\n"
.set marker_len, . - marker

.section .text
.global _start
.type _start,@function
_start:
    mov $1, %rax
    mov $1, %rdi
    lea marker(%rip), %rsi
    mov $marker_len, %rdx
    syscall
1:
    pause
    jmp 1b
INIT
init_source_hash="$(sha256sum "$cache_dir/smoke-init.S" | awk '{print $1}')"
initramfs_key="$(printf '%s\n%s\n%s\n' \
    "$init_source_hash" "$dev_image_id" 'gcc -nostdlib -static x86_64' | sha256sum | awk '{print $1}')"
compiled_init_key_file="$cache_dir/smoke-init.key"
compiled_init_hash_file="$cache_dir/smoke-init.sha256"
compiled_init_hash=""
if [[ -f "$initramfs_root/init" ]]; then
    compiled_init_hash="$(sha256sum "$initramfs_root/init" | awk '{print $1}')"
fi
if [[ "$(cat "$compiled_init_key_file" 2>/dev/null || true)" != "$initramfs_key" || \
      ! -f "$initramfs_root/init" || \
      "$compiled_init_hash" != "$(cat "$compiled_init_hash_file" 2>/dev/null || true)" ]]; then
    docker run --rm --platform linux/amd64 --network none \
        --mount "type=bind,src=$cache_dir,dst=/work/asterinas" \
        --entrypoint /usr/bin/env "$dev_image_id" \
        gcc -nostdlib -static -no-pie -Wl,-e,_start -Wl,--build-id=none \
        -o /work/asterinas/initramfs/root/init.tmp /work/asterinas/smoke-init.S
    docker run --rm --platform linux/amd64 --network none \
        --mount "type=bind,src=$cache_dir,dst=/work/asterinas" \
        --entrypoint /usr/bin/chmod "$dev_image_id" \
        755 /work/asterinas/initramfs/root/init.tmp
    mv -f "$initramfs_root/init.tmp" "$initramfs_root/init"
    readelf -h "$initramfs_root/init" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' || \
        fail 'smoke init is not an x86_64 executable'
    if readelf -l "$initramfs_root/init" | grep -Fq 'INTERP'; then
        fail 'smoke init must be statically linked'
    fi
    compiled_init_hash="$(sha256sum "$initramfs_root/init" | awk '{print $1}')"
    printf '%s\n' "$initramfs_key" > "$compiled_init_key_file.tmp"
    mv -f "$compiled_init_key_file.tmp" "$compiled_init_key_file"
    printf '%s\n' "$compiled_init_hash" > "$compiled_init_hash_file.tmp"
    mv -f "$compiled_init_hash_file.tmp" "$compiled_init_hash_file"
fi

init_binary_hash="$compiled_init_hash"
initramfs_key="$(printf '%s\n%s\n' "$init_binary_hash" 'newc gzip -n -9' | sha256sum | awk '{print $1}')"
initramfs="$cache_dir/smoke-initramfs.cpio.gz"
initramfs_key_file="$cache_dir/smoke-initramfs.key"
initramfs_hash_file="$cache_dir/smoke-initramfs.sha256"
cached_initramfs_hash=""
if [[ -f "$initramfs" ]]; then
    cached_initramfs_hash="$(sha256sum "$initramfs" | awk '{print $1}')"
fi
if [[ ! -f "$initramfs" || \
      "$(cat "$initramfs_key_file" 2>/dev/null || true)" != "$initramfs_key" || \
      "$cached_initramfs_hash" != "$(cat "$initramfs_hash_file" 2>/dev/null || true)" ]]; then
    smoke_file_list="$scratch_dir/smoke-initramfs.files"
    smoke_cpio="$scratch_dir/smoke-initramfs.cpio"
    (cd "$initramfs_root" && find . -print0) | LC_ALL=C sort -z > "$smoke_file_list"
    docker run --rm --interactive --pull never --platform linux/amd64 --network none \
        --mount "type=bind,src=$initramfs_root,dst=/rootfs,readonly" \
        --workdir /rootfs --entrypoint /usr/bin/cpio "$dev_image_id" \
        --null --create --format=newc --reproducible --owner=0:0 \
        < "$smoke_file_list" > "$smoke_cpio"
    docker run --rm --interactive --pull never --platform linux/amd64 --network none \
        --entrypoint /usr/bin/gzip "$dev_image_id" -n -9 -c \
        < "$smoke_cpio" > "$initramfs.tmp"
    docker run --rm --interactive --pull never --platform linux/amd64 --network none \
        --entrypoint /usr/bin/gzip "$dev_image_id" -t - < "$initramfs.tmp"
    mv -f "$initramfs.tmp" "$initramfs"
    initramfs_hash="$(sha256sum "$initramfs" | awk '{print $1}')"
    printf '%s\n' "$initramfs_key" > "$initramfs_key_file.tmp"
    mv -f "$initramfs_key_file.tmp" "$initramfs_key_file"
    printf '%s\n' "$initramfs_hash" > "$initramfs_hash_file.tmp"
    mv -f "$initramfs_hash_file.tmp" "$initramfs_hash_file"
else
    initramfs_hash="$cached_initramfs_hash"
    printf 'Asterinas smoke initramfs is unchanged.\n'
fi

output_initramfs="$output_dir/smoke-initramfs.cpio.gz"
if [[ ! -f "$output_initramfs" || "$(sha256sum "$output_initramfs" | awk '{print $1}')" != "$initramfs_hash" ]]; then
    cp "$initramfs" "$output_initramfs.tmp"
    mv -f "$output_initramfs.tmp" "$output_initramfs"
fi

kernel_build_config='target=x86_64 boot=vmm-direct feature=pvh_boot profile=dev source_mount=/src/asterinas'
kernel_key="$(printf '%s\n' \
    "$asterinas_commit" \
    "$source_snapshot_hash" \
    "$source_state" \
    "$dev_version" \
    "$dev_image_id" \
    "$dev_image_digest" \
    "$toolchain_channel" \
    "$initramfs_hash" \
    "$kernel_build_config" | sha256sum | awk '{print $1}')"
kernel_source="$osdk_output_dir/asterinas/asterinas-osdk-bin.elf"
kernel_output="$output_dir/asterinas.elf"
kernel_sha_file="$output_dir/kernel.sha256"
kernel_key_file="$output_dir/kernel.key"
cached_kernel_hash=""
if [[ -f "$kernel_output" ]]; then
    cached_kernel_hash="$(sha256sum "$kernel_output" | awk '{print $1}')"
fi
if [[ "$(cat "$kernel_key_file" 2>/dev/null || true)" == "$kernel_key" && \
      -f "$kernel_output" && "$cached_kernel_hash" == "$(cat "$kernel_sha_file" 2>/dev/null || true)" ]]; then
    printf 'Asterinas PVH kernel for %s is unchanged.\n' "$asterinas_commit"
else
    osdk_key="$(printf '%s\n%s\n%s\n%s\n' \
        "$asterinas_commit" "$source_snapshot_hash" "$dev_image_id" "$toolchain_channel" | \
        sha256sum | awk '{print $1}')"
    osdk_install="$cache_dir/osdk/$osdk_key"
    if [[ ! -x "$osdk_install/bin/cargo-osdk" ]]; then
        mkdir -p "$osdk_install"
        docker run --rm --platform linux/amd64 --network none \
            --mount "type=bind,src=$source_dir,dst=/src/asterinas,readonly" \
            --mount "type=bind,src=$cache_dir,dst=/work/asterinas" \
            --workdir /src/asterinas \
            --env CARGO_HOME=/work/asterinas/cargo \
            --env CARGO_TARGET_DIR=/work/asterinas/target \
            --env RUSTUP_TOOLCHAIN="$toolchain_channel" \
            --env OSDK_LOCAL_DEV=1 \
            --env "OSDK_INSTALL_ROOT=/work/asterinas/osdk/$osdk_key" \
            --entrypoint /usr/bin/env "$dev_image_id" \
            cargo install --locked --offline --force cargo-osdk --path osdk --root "/work/asterinas/osdk/$osdk_key"
        [[ -x "$osdk_install/bin/cargo-osdk" ]] || fail 'OSDK install did not produce cargo-osdk'
    fi
    docker run --rm --platform linux/amd64 \
        --network none \
        --mount "type=bind,src=$source_dir,dst=/src/asterinas,readonly" \
        --mount "type=bind,src=$cache_dir,dst=/work/asterinas" \
        --workdir /src/asterinas/kernel \
        --env CARGO_HOME=/work/asterinas/cargo \
        --env CARGO_TARGET_DIR=/work/asterinas/target \
        --env CARGO_NET_OFFLINE=true \
        --env RUSTUP_TOOLCHAIN="$toolchain_channel" \
        --env VDSO_LIBRARY_DIR=/root/linux_vdso \
        --entrypoint "/work/asterinas/osdk/$osdk_key/bin/cargo-osdk" "$dev_image_id" \
        osdk build --initramfs=/work/asterinas/smoke-initramfs.cpio.gz \
        --boot-method=vmm-direct --target-arch=x86_64 --features pvh_boot \
        --output=/work/asterinas/osdk-output \
        2>&1 | tee "$output_dir/kernel-build.log"
    [[ "$(asterinas_source_hash)" == "$source_snapshot_hash" ]] || \
        fail 'Asterinas source changed during the kernel build; rerun with a stable working tree'
    [[ -f "$kernel_source" ]] || fail "Asterinas OSDK did not produce the expected ELF: $kernel_source"
    readelf -h "$kernel_source" | grep -Eq 'Class:[[:space:]]+ELF64' || \
        fail 'Asterinas kernel is not an ELF64 image'
    # OSDK sets e_machine to EM_386 for QEMU while preserving the ELF64 PVH image.
    readelf -n "$kernel_source" | grep -Fq 'Unknown note type: (0x00000012)' || \
        fail 'Asterinas kernel is missing the Xen PVH physical entry note'
    kernel_tmp="$kernel_output.tmp.$$"
    cp "$kernel_source" "$kernel_tmp"
    chmod 644 "$kernel_tmp"
    mv -f "$kernel_tmp" "$kernel_output"
    kernel_hash="$(sha256sum "$kernel_output" | awk '{print $1}')"
    printf '%s\n' "$kernel_key" > "$kernel_key_file.tmp"
    mv -f "$kernel_key_file.tmp" "$kernel_key_file"
    printf '%s\n' "$kernel_hash" > "$kernel_sha_file.tmp"
    mv -f "$kernel_sha_file.tmp" "$kernel_sha_file"
fi

readelf -h "$kernel_output" | grep -Eq 'Class:[[:space:]]+ELF64' || \
    fail 'cached Asterinas kernel is not an ELF64 image'
readelf -n "$kernel_output" | grep -Fq 'Unknown note type: (0x00000012)' || \
    fail 'cached Asterinas kernel is missing the Xen PVH physical entry note'
kernel_hash="$(sha256sum "$kernel_output" | awk '{print $1}')"

printf 'Asterinas commit: %s\n' "$asterinas_commit" > "$output_dir/setup.txt"
printf 'Asterinas source snapshot SHA-256: %s\n' "$source_snapshot_hash" >> "$output_dir/setup.txt"
printf 'Asterinas source state: %s\n' "$source_state" >> "$output_dir/setup.txt"
printf 'Rust toolchain channel: %s\n' "$toolchain_channel" >> "$output_dir/setup.txt"
printf 'Asterinas dev image: %s (%s)\n' "$dev_version" "$dev_image_digest" >> "$output_dir/setup.txt"
printf 'Kernel build config: %s\n' "$kernel_build_config" >> "$output_dir/setup.txt"
printf 'Cargo: %s\n' "$toolchain_cargo_version" >> "$output_dir/setup.txt"
printf 'Rustc: %s\n' "$toolchain_rustc_version" >> "$output_dir/setup.txt"
printf 'GCC: %s\n' "$toolchain_gcc_version" >> "$output_dir/setup.txt"
printf 'Firecracker: %s\n' "$firecracker_version" >> "$output_dir/setup.txt"
printf 'Kernel SHA-256: %s\n' "$kernel_hash" >> "$output_dir/setup.txt"
if [[ "$mode" == build ]]; then
    printf 'Asterinas PVH kernel for %s is ready.\n' "$asterinas_commit"
    cat "$output_dir/setup.txt"
    exit 0
fi

config_tmp="$output_dir/firecracker.json.tmp"
docker run --rm --platform linux/amd64 --network none --entrypoint /usr/bin/jq "$dev_image_id" \
    -n --arg kernel "$kernel_output" --arg initramfs "$output_initramfs" \
    '{"boot-source":{"kernel_image_path":$kernel,"initrd_path":$initramfs,"boot_args":"console=ttyS0 earlycon loglevel=error i8042.exist rdinit=/init"},"drives":[],"machine-config":{"vcpu_count":2,"mem_size_mib":1024}}' \
    > "$config_tmp"
mv -f "$config_tmp" "$output_dir/firecracker.json"

console_log="$output_dir/smoke-console.log"
firecracker_log="$output_dir/smoke-firecracker.log"
: > "$console_log"
: > "$firecracker_log"
"$firecracker_bin" --no-api --config-file "$output_dir/firecracker.json" \
    </dev/null >"$console_log" 2>"$firecracker_log" &
firecracker_pid=$!

booted=false
for _ in {1..225}; do
    if grep -Fq ASTERINAS_PVH_BOOT_OK "$console_log"; then
        booted=true
        break
    fi
    state="$(ps -o stat= -p "$firecracker_pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ -z "$state" || "$state" == Z* ]]; then
        vm_status=0
        wait "$firecracker_pid" || vm_status=$?
        firecracker_pid=""
        fail "Firecracker exited with status $vm_status before the Asterinas init marker"
    fi
    sleep 0.2
done

[[ "$booted" == true ]] || fail 'timed out waiting for the Asterinas PVH guest init marker'
stop_firecracker
printf 'Asterinas commit: %s\n' "$asterinas_commit" > "$output_dir/setup.txt"
printf 'Asterinas source snapshot SHA-256: %s\n' "$source_snapshot_hash" >> "$output_dir/setup.txt"
printf 'Asterinas source state: %s\n' "$source_state" >> "$output_dir/setup.txt"
printf 'Rust toolchain channel: %s\n' "$toolchain_channel" >> "$output_dir/setup.txt"
printf 'Asterinas dev image: %s (%s)\n' "$dev_version" "$dev_image_digest" >> "$output_dir/setup.txt"
printf 'Kernel build config: %s\n' "$kernel_build_config" >> "$output_dir/setup.txt"
printf 'Cargo: %s\n' "$toolchain_cargo_version" >> "$output_dir/setup.txt"
printf 'Rustc: %s\n' "$toolchain_rustc_version" >> "$output_dir/setup.txt"
printf 'GCC: %s\n' "$toolchain_gcc_version" >> "$output_dir/setup.txt"
printf 'Firecracker: %s\n' "$firecracker_version" >> "$output_dir/setup.txt"
printf 'Kernel SHA-256: %s\n' "$kernel_hash" >> "$output_dir/setup.txt"
printf 'Guest proof: ASTERINAS_PVH_BOOT_OK observed on ttyS0\n' >> "$output_dir/setup.txt"
printf 'Guest proof: ASTERINAS_PVH_BOOT_OK observed on ttyS0\n' > "$output_dir/smoke-result.txt"

printf '\nAsterinas PVH boot reached the guest init process.\n'
cat "$output_dir/setup.txt"
printf '\n--- Guest serial output ---\n'
grep -F -e 'running /init' -e 'ASTERINAS_PVH_BOOT_OK' "$console_log"
printf '\nArtifacts and logs: %s\n' "$output_dir"
