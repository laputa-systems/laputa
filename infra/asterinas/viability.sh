#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
requested_mode="${1:-test}"
case "$requested_mode" in
    build) action=build; mode=viability ;;
    test|viability) action=test; mode=viability ;;
    boot|shell) action=boot; mode=shell ;;
    *) printf 'usage: %s [build|test|boot]\n' "$0" >&2; exit 2 ;;
esac
unset XSH_BIN_DIR XSH_HOST
source "$repo_root/infra/asterinas/inputs.lock"
output_dir="$repo_root/.out/asterinas-firecracker"
source_cache="${SOURCE_CACHE:-$repo_root/.cache/sources}"
firecracker_bin="$output_dir/bin/firecracker"
firecracker_log="$output_dir/$action-firecracker.log"
console_log="$output_dir/$action-console.log"
firecracker_pid=""
restore_standard_seed=false

fail() {
    printf 'asterinas-%s: %s\n' "$action" "$*" >&2
    if [[ -s "$console_log" ]]; then
        printf '\n--- Asterinas guest console ---\n' >&2
        tail -n 80 "$console_log" >&2 || true
    fi
    if [[ -s "$firecracker_log" ]]; then
        printf '\n--- Firecracker diagnostics ---\n' >&2
        tail -n 60 "$firecracker_log" >&2 || true
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
    if [[ "$restore_standard_seed" == true ]]; then
        run_make seed || printf 'asterinas-boot: could not restore the ordinary XSH seed\n' >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for tool in awk cat cc chmod cp dirname docker find git grep head make mkdir mv ps readlink sed sha256sum sleep sort stat tail tr uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required host command is missing: $tool"
done
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail 'requires an x86_64 Linux host'
if [[ "$action" != build ]]; then
    [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || fail '/dev/kvm must exist and be readable and writable by this user'
fi
docker info >/dev/null 2>&1 || fail 'Docker is unavailable to this user'
mkdir -p "$output_dir/logs"

xsh_snapshot_output="$(bash "$repo_root/infra/asterinas/prepare-xsh.sh")"
readarray -t xsh_snapshot <<< "$xsh_snapshot_output"
[[ ${#xsh_snapshot[@]} -eq 2 ]] || fail 'pinned XSH snapshot helper returned invalid output'
xsh_root="${xsh_snapshot[0]}"
xsh_build_inputs_hash="${xsh_snapshot[1]}"
actual_xsh_commit="$XSH_COMMIT"

make_args=("XSH_ROOT=$xsh_root" "XSH_BIN_DIR=$repo_root/.out/host/x86_64" ARCH=x86_64)
bash "$repo_root/infra/asterinas/setup.sh" build
make -C "$repo_root" "${make_args[@]}" host-xsh

xsh_bin_dir="$repo_root/.out/host/x86_64"
host_xsh="$xsh_bin_dir/xsh"
[[ -x "$host_xsh" ]] || fail "host XSH is missing: $host_xsh"
export XSH_ROOT="$xsh_root"
export XSH_MODULE_PATH="$repo_root"
export XSH_HOST="$host_xsh"
export PATH="$xsh_bin_dir:$PATH"
export LAPUTA_SOURCE_CACHE="$source_cache"

run_make() {
    make -C "$repo_root" "${make_args[@]}" "$@"
}

run_make fetch-seed
"$host_xsh" "$repo_root/pm.xsh" -- sources fetch --repo "$repo_root" --target x86_64-linux-musl llvm-toolchain
if [[ "$mode" == shell ]]; then
    restore_standard_seed=true
    run_make seed-asterinas-shell
else
    run_make seed
fi
packages=(baselayout xsh laputa-pm xinit)
package_selection="${packages[*]}"
run_make plan "PKGS=$package_selection"
plan_path="$repo_root/.out/world/x86_64/plan.json"
[[ -f "$plan_path" ]] || fail "PM did not write its plan: $plan_path"
"$host_xsh" "$repo_root/infra/asterinas/fetch-plan-sources.xsh" -- "$plan_path"
run_make build "PKGS=$package_selection"

if [[ "$mode" == shell ]]; then
    run_make seed
    restore_standard_seed=false
fi

"$host_xsh" "$repo_root/infra/asterinas/compose-image.xsh" -- x86_64 "$mode"
root_image="$output_dir/laputa-root.ext2"
[[ -f "$root_image" ]] || fail 'PM image builder did not produce the ext2 root'

dev_version="$(cat "$repo_root/.cache/asterinas/source/DOCKER_IMAGE_VERSION")"
dev_image_id="$(docker image inspect --format '{{.Id}}' "asterinas/dev:$dev_version")"
initramfs_root="$output_dir/initramfs-root"
initramfs="$output_dir/laputa-initramfs.cpio.gz"
initramfs_key_file="$output_dir/laputa-initramfs.key"
initramfs_sha_file="$output_dir/laputa-initramfs.sha256"
init_source="$repo_root/guest/asterinas/initramfs/init.c"
init_binary="$output_dir/initramfs-init"
init_build_key_file="$output_dir/initramfs-init.key"
init_source_hash="$(sha256sum "$init_source" | awk '{print $1}')"
compiler_version="$(cc --version | head -n 1)"
init_build_flags=(-ffreestanding -fno-builtin -fno-pie -fno-stack-protector -mno-sse -mno-mmx -nostdlib -static -no-pie -O2 -Wl,-e,_start -Wl,--build-id=none)
init_build_key="$(printf '%s\n%s\n%s\n' "$init_source_hash" "$compiler_version" "${init_build_flags[*]}" | sha256sum | awk '{print $1}')"
if [[ ! -f "$init_binary" || "$(cat "$init_build_key_file" 2>/dev/null || true)" != "$init_build_key" ]]; then
    cc "${init_build_flags[@]}" "$init_source" -o "$init_binary.tmp"
    mv -f "$init_binary.tmp" "$init_binary"
    printf '%s\n' "$init_build_key" > "$init_build_key_file.tmp"
    mv -f "$init_build_key_file.tmp" "$init_build_key_file"
fi
init_hash="$(sha256sum "$init_binary" | awk '{print $1}')"
initramfs_key="$(printf '%s\n%s\n' "$init_hash" "$dev_image_id" | sha256sum | awk '{print $1}')"
initramfs_hash=""
if [[ -f "$initramfs" ]]; then
    initramfs_hash="$(sha256sum "$initramfs" | awk '{print $1}')"
fi
if [[ "$(cat "$initramfs_key_file" 2>/dev/null || true)" != "$initramfs_key" || \
      ! -f "$initramfs" || "$initramfs_hash" != "$(cat "$initramfs_sha_file" 2>/dev/null || true)" ]]; then
    rm -rf "$initramfs_root"
    mkdir -p "$initramfs_root/dev" "$initramfs_root/newroot" "$initramfs_root/proc" "$initramfs_root/sys"
    cp "$init_binary" "$initramfs_root/init"
    chmod 755 "$initramfs_root/init"
    "$host_xsh" "$repo_root/infra/asterinas/pack-initramfs.xsh" -- "$initramfs_root" "$initramfs" "$dev_image_id"
    initramfs_hash="$(sha256sum "$initramfs" | awk '{print $1}')"
    printf '%s\n' "$initramfs_key" > "$initramfs_key_file.tmp"
    mv -f "$initramfs_key_file.tmp" "$initramfs_key_file"
    printf '%s\n' "$initramfs_hash" > "$initramfs_sha_file.tmp"
    mv -f "$initramfs_sha_file.tmp" "$initramfs_sha_file"
else
    printf 'Laputa initramfs is unchanged.\n'
fi

config_tmp="$output_dir/laputa-firecracker.json.tmp"
docker run --rm --pull never --platform linux/amd64 --network none --entrypoint /usr/bin/jq "$dev_image_id" \
    -n --arg kernel "$output_dir/asterinas.elf" --arg initramfs "$initramfs" --arg root "$root_image" \
    '{"boot-source":{"kernel_image_path":$kernel,"initrd_path":$initramfs,"boot_args":"console=ttyS0 earlycon loglevel=error i8042.exist rdinit=/init"},"drives":[{"drive_id":"laputa-root","path_on_host":$root,"is_root_device":true,"is_read_only":false}],"machine-config":{"vcpu_count":2,"mem_size_mib":1024}}' \
    > "$config_tmp"
mv -f "$config_tmp" "$output_dir/laputa-firecracker.json"

generation="$(cat "$output_dir/generation.path")"
[[ "$generation" =~ ^[0-9a-f]{64}$ ]] || fail 'PM generation identity is invalid'
generation_path="$output_dir/generations/$generation"
package_tools_image="$(cat "$output_dir/package-tools-image")"
kernel_hash="$(sha256sum "$output_dir/asterinas.elf" | awk '{print $1}')"
root_hash="$(sha256sum "$root_image" | awk '{print $1}')"
initramfs_hash="$(sha256sum "$initramfs" | awk '{print $1}')"
bundle_key="$(printf '%s\n' "$mode" "$generation" "$actual_xsh_commit" "$xsh_build_inputs_hash" "$ASTERINAS_COMMIT" "$ASTERINAS_DEV_IMAGE_DIGEST" "$FIRECRACKER_VERSION" "$package_tools_image" "$kernel_hash" "$root_hash" "$initramfs_hash" 'writable-runtime-root-v1' | sha256sum | awk '{print $1}')"
bundle_dir="$output_dir/builds/$bundle_key"
runtime_root="$output_dir/runtime/$bundle_key/laputa-root.ext2"
mkdir -p "$output_dir/builds"
if [[ -d "$bundle_dir" ]]; then
    (cd "$bundle_dir" && sha256sum -c SHA256SUMS) || fail "immutable bundle failed checksum verification: $bundle_dir"
else
    bundle_stage="$output_dir/builds/.${bundle_key}.tmp.$$"
    rm -rf "$bundle_stage"
    mkdir -p "$bundle_stage"
    cp "$output_dir/asterinas.elf" "$bundle_stage/kernel.elf"
    cp "$root_image" "$bundle_stage/laputa-root.ext2"
    cp "$initramfs" "$bundle_stage/laputa-initramfs.cpio.gz"
    cp "$plan_path" "$bundle_stage/pm-plan.json"
    cp "$generation_path/var/lib/laputa/generation.json" "$bundle_stage/generation.json"
    cp "$repo_root/infra/asterinas/inputs.lock" "$bundle_stage/inputs.lock"
    printf '%s\n' "$package_tools_image" > "$bundle_stage/package-tools-image"
    docker run --rm --pull never --platform linux/amd64 --network none --entrypoint /usr/bin/jq "$dev_image_id" \
        -n --arg key "$bundle_key" --arg profile "$mode" --arg generation "$generation" \
        --arg xsh_commit "$actual_xsh_commit" --arg xsh_inputs "$xsh_build_inputs_hash" \
        --arg asterinas_commit "$ASTERINAS_COMMIT" --arg dev_image_digest "$ASTERINAS_DEV_IMAGE_DIGEST" \
        --arg firecracker "$FIRECRACKER_VERSION" --arg package_tools "$package_tools_image" \
        --arg kernel_sha "$kernel_hash" --arg root_sha "$root_hash" --arg initramfs_sha "$initramfs_hash" \
        '{schema_version:1,build_key:$key,profile:$profile,pm_generation:$generation,xsh:{commit:$xsh_commit,build_inputs_sha256:$xsh_inputs},asterinas:{commit:$asterinas_commit,dev_image_digest:$dev_image_digest},firecracker:{version:$firecracker},package_tools_image:$package_tools,artifacts:{kernel:{path:"kernel.elf",sha256:$kernel_sha},rootfs:{path:"laputa-root.ext2",format:"ext2",sha256:$root_sha},initramfs:{path:"laputa-initramfs.cpio.gz",format:"newc+gzip",sha256:$initramfs_sha}}}' \
        > "$bundle_stage/manifest.json"
    docker run --rm --pull never --platform linux/amd64 --network none --entrypoint /usr/bin/jq "$dev_image_id" \
        -n --arg kernel "$bundle_dir/kernel.elf" --arg initramfs "$bundle_dir/laputa-initramfs.cpio.gz" \
        --arg root "$runtime_root" \
        '{"boot-source":{"kernel_image_path":$kernel,"initrd_path":$initramfs,"boot_args":"console=ttyS0 earlycon loglevel=error i8042.exist rdinit=/init"},"drives":[{"drive_id":"laputa-root","path_on_host":$root,"is_root_device":true,"is_read_only":false}],"machine-config":{"vcpu_count":2,"mem_size_mib":1024}}' \
        > "$bundle_stage/firecracker.json"
    (cd "$bundle_stage" && sha256sum kernel.elf laputa-root.ext2 laputa-initramfs.cpio.gz pm-plan.json generation.json inputs.lock package-tools-image manifest.json firecracker.json > SHA256SUMS)
    chmod -R a-w "$bundle_stage"
    mv "$bundle_stage" "$bundle_dir"
fi
ln -sfn "builds/$bundle_key" "$output_dir/current.tmp.$$"
mv -Tf "$output_dir/current.tmp.$$" "$output_dir/current"

kernel_output="$bundle_dir/kernel.elf"
root_image="$bundle_dir/laputa-root.ext2"
initramfs="$bundle_dir/laputa-initramfs.cpio.gz"
firecracker_config="$bundle_dir/firecracker.json"
printf 'Asterinas Laputa bundle: %s\n' "$bundle_dir"
if [[ "$action" == build ]]; then
    exit 0
fi

mkdir -p "$(dirname "$runtime_root")"
cp "$bundle_dir/laputa-root.ext2" "$runtime_root"
chmod u+w "$runtime_root"
[[ "$(sha256sum "$runtime_root" | awk '{print $1}')" == "$(sha256sum "$bundle_dir/laputa-root.ext2" | awk '{print $1}')" ]] || \
    fail 'writable Firecracker root copy does not match the verified bundle image'

: > "$console_log"
: > "$firecracker_log"
if [[ "$mode" == shell ]]; then
    [[ -t 0 ]] || fail 'make asterinas-boot needs an interactive terminal'
    "$firecracker_bin" --no-api --config-file "$firecracker_config" \
        </dev/tty > >(tee -a "$console_log") 2>"$firecracker_log" &
else
    "$firecracker_bin" --no-api --config-file "$firecracker_config" \
        </dev/null >"$console_log" 2>"$firecracker_log" &
fi
firecracker_pid=$!

if [[ "$mode" == shell ]]; then
    ready=false
    for _ in {1..600}; do
        if grep -Fq LAPUTA_ASTERINAS_TEST_FAILED "$console_log"; then
            fail 'guest reported a failed shell boot check'
        fi
        if grep -Fq LAPUTA_ASTERINAS_SHELL_READY "$console_log"; then
            ready=true
            break
        fi
        state="$(ps -o stat= -p "$firecracker_pid" 2>/dev/null | tr -d ' ' || true)"
        if [[ -z "$state" || "$state" == Z* ]]; then
            vm_status=0
            wait "$firecracker_pid" || vm_status=$?
            firecracker_pid=""
            fail "Firecracker exited with status $vm_status before xshi started"
        fi
        sleep 0.2
    done
    [[ "$ready" == true ]] || fail 'timed out waiting for xinit and the interactive xshi shell'
    printf '\nLaputa xshi is ready. Run laputa-exit in the guest to stop Firecracker; Ctrl-C interrupts the guest shell.\n'
    while true; do
        if grep -Fq LAPUTA_ASTERINAS_SHELL_EXIT "$console_log"; then
            stop_firecracker
            printf 'Firecracker shell session ended.\n'
            exit 0
        fi
        if grep -Fq LAPUTA_ASTERINAS_TEST_FAILED "$console_log"; then
            fail 'guest reported a failed shell session'
        fi
        state="$(ps -o stat= -p "$firecracker_pid" 2>/dev/null | tr -d ' ' || true)"
        if [[ -z "$state" || "$state" == Z* ]]; then
            vm_status=0
            wait "$firecracker_pid" || vm_status=$?
            firecracker_pid=""
            fail "Firecracker exited with status $vm_status during the shell session"
        fi
        sleep 0.2
    done
fi

complete=false
for _ in {1..300}; do
    if grep -Fq LAPUTA_ASTERINAS_TEST_FAILED "$console_log"; then
        fail 'guest reported a failed Laputa proof'
    fi
    if grep -Eq 'Kernel panic|panicked at|Uncaught panic|failed to run the init process' "$console_log"; then
        fail 'Asterinas reported a kernel or init failure'
    fi
    if grep -Fq LAPUTA_ASTERINAS_TEST_OK "$console_log"; then
        complete=true
        break
    fi
    state="$(ps -o stat= -p "$firecracker_pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ -z "$state" || "$state" == Z* ]]; then
        vm_status=0
        wait "$firecracker_pid" || vm_status=$?
        firecracker_pid=""
        fail "Firecracker exited with status $vm_status before the guest completion marker"
    fi
    sleep 0.2
done
[[ "$complete" == true ]] || fail 'timed out waiting for the Laputa guest completion marker'

"$host_xsh" "$repo_root/infra/asterinas/check-guest-output.xsh" -- "$console_log" || \
    fail 'guest completion is missing a required proof marker'

stop_firecracker

generation="$(cat "$output_dir/generation.path")"
generation_path="$output_dir/generations/$generation"
kernel_hash="$(sha256sum "$bundle_dir/kernel.elf" | awk '{print $1}')"
root_hash="$(sha256sum "$root_image" | awk '{print $1}')"
firecracker_version="$(cat "$output_dir/firecracker.version")"
asterinas_commit="$(cat "$output_dir/setup.txt" | sed -n 's/^Asterinas commit: //p')"
cat > "$output_dir/viability-result.txt" <<RESULT
PM generation: $generation
Bundle key: $bundle_key
Bundle directory: $bundle_dir
Asterinas commit: $asterinas_commit
XSH commit: $actual_xsh_commit
XSH build inputs SHA-256: $xsh_build_inputs_hash
Firecracker: $firecracker_version
Kernel SHA-256: $kernel_hash
Ext2 root SHA-256: $root_hash
Guest proofs: LAPUTA_ASTERINAS_EXT2_MOUNT_OK, LAPUTA_ASTERINAS_SWITCH_ROOT_START, LAPUTA_ASTERINAS_BOOT_SETUP_OK, LAPUTA_ASTERINAS_XINIT_PID1_OK, LAPUTA_ASTERINAS_ROOTFS_OK, LAPUTA_ASTERINAS_XSH_OK, LAPUTA_ASTERINAS_TEST_OK
VM completion: Firecracker stopped by the host after all guest proof markers
Guest serial log: $console_log
Firecracker log: $firecracker_log
RESULT

cat "$output_dir/viability-result.txt"
printf 'Guest serial log: %s\n' "$console_log"
