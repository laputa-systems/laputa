#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/run-cancellable.sh"
[[ $# == 2 ]] || { printf 'usage: storage-cohort.sh linux|asterinas|both CASE\n' >&2; exit 2; }
backend="$1"
selected="$2"
case "$backend" in linux) backends=(linux) ;; asterinas) backends=(asterinas) ;; both) backends=(linux asterinas) ;; *) exit 2 ;; esac
cases=(dirty full unclean corrupt)
if [[ -n "$selected" ]]; then
    [[ " ${cases[*]} " == *" $selected "* ]] || { printf 'qualification: unknown storage case: %s\n' "$selected" >&2; exit 2; }
    cases=("$selected")
fi

output="$repo_root/.out/asterinas-firecracker"
bundle="$(realpath "$output/current")"
host_xsh="$repo_root/.out/host/x86_64/xsh"
dev_image="$(docker image inspect --format '{{.Id}}' "asterinas/dev:$(cat "$repo_root/asterinas/DOCKER_IMAGE_VERSION")")"
memory_mib="$(jaq -r '."machine-config".mem_size_mib' "$bundle/firecracker.json")"
regression="$repo_root/asterinas/test/initramfs/src/regression"
witness_source="$regression/storage/qualify.c"
linux_package="${LAPUTA_LINUX_KERNEL_PACKAGE:-$output/linux-package.tar.gz}"
mkdir -p "$repo_root/.work/tmp"
export TMPDIR="$repo_root/.work/tmp"
work="$(mktemp -d "$TMPDIR/storage.XXXXXXXX")"
failed=0
passed=0

cancellable_cancelled() { rm -rf -- "$work"; }

big_image_mib=256
small_image_mib=16
prepare_image_mib=32

note() { printf 'qualification: %s\n' "$*"; }
fail_case() { printf 'qualification: %s\n' "$*" >&2; failed=1; }

make_image() {
    local path="$1" mib="$2"
    rm -f "$path"
    truncate -s "${mib}M" "$path"
    mke2fs -q -t ext2 -b 4096 -F "$path"
}

superblock_word() {
    od -An -tu2 -N2 -j "$(( 1024 + $2 ))" "$1" | tr -d ' '
}

superblock_state() { superblock_word "$1" 58; }
superblock_mount_count() { superblock_word "$1" 52; }

image_digest() { sha256sum "$1" | awk '{print $1}'; }

compile_witness() {
    local side="$1" directory="$2"
    mkdir -p "$directory"
    run_cancellable "" docker run --rm --pull never --platform linux/amd64 --network none --entrypoint /usr/bin/gcc \
        --mount "type=bind,src=$regression,dst=/regression,readonly" \
        --mount "type=bind,src=$directory,dst=/out" \
        "$dev_image" -Wall -Werror -static -pthread $([[ "$side" != asterinas ]] || printf %s -D__asterinas__) \
        -o /out/witness "/regression/storage/$(basename "$witness_source")" || return 1
}

inject_case() {
    local directory="$1" witness="$2" mode="$3"
    rm -rf "$directory/root"
    mkdir -p "$directory/root"
    cp "$bundle/laputa-root.ext2" "$directory/root/root.ext2"
    chmod u+w "$directory/root/root.ext2"
    printf '%s\n' "$mode" > "$directory/root/storage.mode"
    printf '%s\n' "storage-$mode" > "$directory/root/witness.name"
    run_cancellable "" bash "$repo_root/infra/asterinas/inject-guest-file.sh" \
        "$directory/root/root.ext2" "$witness" usr/lib/asterinas/witness "$dev_image" > /dev/null || return 1
    run_cancellable "" bash "$repo_root/infra/asterinas/inject-guest-file.sh" \
        "$directory/root/root.ext2" "$directory/root/witness.name" usr/lib/asterinas/witness.name "$dev_image" > /dev/null || return 1
    run_cancellable "" bash "$repo_root/infra/asterinas/inject-guest-file.sh" \
        "$directory/root/root.ext2" "$directory/root/storage.mode" usr/lib/asterinas/storage.mode "$dev_image" > /dev/null || return 1
}

run_vm() {
    local side="$1" base="$2" directory="$3" state="$4" kill_marker="$5" timeout="$6"
    local root="$directory/root/root.ext2"
    local console="$directory/console.log" backend_log="$directory/vmm.log"
    if [[ "$side" == asterinas ]]; then
        jaq --arg root "$root" --arg state "$state" \
            '.drives[0].path_on_host = $root | .drives += [{drive_id: "storage-state", path_on_host: $state, is_root_device: false, is_read_only: false}]' \
            "$bundle/firecracker.json" > "$directory/firecracker.json"
        XSH_MODULE_PATH="$repo_root" run_cancellable "" "$host_xsh" "$repo_root/infra/asterinas/run-storage-vm.xsh" -- \
            firecracker "$output/bin/firecracker" "$directory/firecracker.json" '' '' \
            "$root" "$state" "$console" "$backend_log" "$kill_marker" "$timeout" --memory-mib "$memory_mib" \
            > "$directory/runner.log" 2>&1
    else
        XSH_MODULE_PATH="$repo_root" run_cancellable "" "$host_xsh" "$repo_root/infra/asterinas/run-storage-vm.xsh" -- \
            qemu '' '' "$base/linux-reference/linux-kernel" "$base/linux-reference/linux-initramfs.cpio.gz" \
            "$root" "$state" "$console" "$backend_log" "$kill_marker" "$timeout" --memory-mib "$memory_mib" \
            > "$directory/runner.log" 2>&1
    fi
}

classify() {
    local source="$1" directory="$2" label="$3"
    local checked="$directory/$label-check.img" repaired="$directory/$label-repair.img"
    local rc=0 rc2=0 rc3=0
    cp "$source" "$checked"
    e2fsck -fn "$checked" > "$directory/$label-fn.log" 2>&1 || rc=$?
    if (( rc == 0 )); then
        printf 'clean'
        return 0
    fi
    cp "$source" "$repaired"
    e2fsck -fy "$repaired" > "$directory/$label-fy.log" 2>&1 || rc2=$?
    if (( rc2 == 1 || rc2 == 2 )); then
        e2fsck -fn "$repaired" > "$directory/$label-recheck.log" 2>&1 || rc3=$?
        if (( rc3 != 0 )); then
            printf 'unrecoverable'
            return 0
        fi
        printf 'repaired'
        return 0
    fi
    printf 'unrecoverable'
}

storage_lines() {
    sed 's/\x1b\[[0-9;]*m//g' "$1" | tr -d '\r' | rg '^STORAGE_' | rg -v '^STORAGE_WRITING ' || true
}

normalize_transcript() {
    local case_name="$1"
    case "$case_name" in
        full) sed -E 's/^(STORAGE_FULL_DONE) .*/\1/' ;;
        corrupt) sed -E 's/^(STORAGE_CORRUPT_REFUSED) .*/\1/' ;;
        *) cat ;;
    esac
}

require_console() {
    local directory="$1" marker="$2"
    rg -q "$marker" "$directory/console.log" || { fail_case "missing guest marker $marker in $directory/console.log"; return 1; }
}

record_transcript() {
    local directory="$1" transcript="$2"
    storage_lines "$directory/console.log" >> "$transcript"
}

verify_payload() {
    local side="$1" base="$2" boot="$3" witness="$4" state="$5" expected="$6" logs="$7"
    mkdir -p "$boot"
    inject_case "$boot" "$witness" verify || { fail_case "could not stage the $side verify guest"; return 1; }
    local mounts_before valid_before
    mounts_before="$(superblock_mount_count "$state")"
    valid_before=$(( $(superblock_state "$state") & 1 ))
    run_vm "$side" "$base" "$boot" "$state" "" 900 || { fail_case "verify guest failed on $side"; return 1; }
    require_console "$boot" "STORAGE_VERIFY_OK" || return 1
    local actual
    actual="$(rg '^STORAGE_VERIFY ' "$boot/console.log" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | tail -n 1)"
    if [[ "$actual" != "$expected" ]]; then
        fail_case "$side verify mismatch: expected '$expected', got '$actual'"
        return 1
    fi
    local rc=0
    e2fsck -fn "$state" > "$logs/verify-fn.log" 2>&1 || rc=$?
    (( rc == 0 )) || { fail_case "$side verify image is not clean after unmount (e2fsck $rc)"; return 1; }
    local state_word mounts_after valid_after
    state_word="$(superblock_state "$state")"
    valid_after=$(( state_word & 1 ))
    (( valid_after == valid_before )) || {
        fail_case "$side verify image changed its clean-unmount flag (was $valid_before, now $valid_after)"
        return 1
    }
    mounts_after="$(superblock_mount_count "$state")"
    (( mounts_after == mounts_before + 1 )) || {
        fail_case "$side mount count did not advance from $mounts_before to $mounts_after"
        return 1
    }
}

run_dirty() {
    local side="$1" base="$2"
    local directory="$base/dirty"
    local transcript="$directory/transcript"
    mkdir -p "$directory"
    : > "$transcript"
    make_image "$directory/state.img" "$big_image_mib"
    inject_case "$directory" "$base/witness" stage || { fail_case "could not stage the $side dirty guest"; return 1; }
    local mounts_before
    mounts_before="$(superblock_mount_count "$directory/state.img")"
    run_vm "$side" "$base" "$directory" "$directory/state.img" "STORAGE_WRITING 0" 900 || {
        fail_case "dirty guest did not reach its write marker on $side"
        return 1
    }
    record_transcript "$directory" "$transcript"
    require_console "$directory" "STORAGE_SYNCED" || return 1
    rg -q '^STORAGE_VMM_KILLED$' "$directory/runner.log" || {
        fail_case "dirty guest VMM was not killed on $side"
        return 1
    }
    local payload_line
    payload_line="$(rg '^STORAGE_PAYLOAD ' "$directory/console.log" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | tail -n 1)"
    [[ -n "$payload_line" ]] || { fail_case "dirty guest printed no payload identity on $side"; return 1; }
    local state_word mounts_after
    state_word="$(superblock_state "$directory/state.img")"
    (( (state_word & 1) == 0 )) || { fail_case "dirty image is still marked clean on $side (state $state_word)"; return 1; }
    mounts_after="$(superblock_mount_count "$directory/state.img")"
    (( mounts_after == mounts_before + 1 )) || {
        fail_case "$side dirty mount count did not advance from $mounts_before to $mounts_after"
        return 1
    }

    local class
    class="$(classify "$directory/state.img" "$directory" dirty)"
    printf '%s\n' "$class" > "$directory/classification"
    [[ "$class" != unrecoverable ]] || {
        fail_case "dirty shutdown was unrecoverable on $side; see $directory/dirty-fn.log"
        return 1
    }
    local source="$directory/state.img"
    [[ "$class" != repaired ]] || source="$directory/dirty-repair.img"
    local expected="${payload_line/STORAGE_PAYLOAD/STORAGE_VERIFY}"
    verify_payload "$side" "$base" "$directory/verify" "$base/witness" "$source" "$expected" "$directory" || return 1
    record_transcript "$directory/verify" "$transcript"
    passed=$((passed + 1))
    note "storage dirty passed for $side ($class)"
}

run_full() {
    local side="$1" base="$2"
    local directory="$base/full"
    local transcript="$directory/transcript"
    mkdir -p "$directory"
    : > "$transcript"
    make_image "$directory/state.img" "$small_image_mib"
    inject_case "$directory" "$base/witness" full || { fail_case "could not stage the $side full guest"; return 1; }
    local mounts_before
    mounts_before="$(superblock_mount_count "$directory/state.img")"
    run_vm "$side" "$base" "$directory" "$directory/state.img" "" 900 || { fail_case "full guest failed on $side"; return 1; }
    record_transcript "$directory" "$transcript"
    require_console "$directory" "STORAGE_FULL_ENOSPC 28" || return 1
    require_console "$directory" "STORAGE_FULL_DONE" || return 1
    local payload_line
    payload_line="$(rg '^STORAGE_PAYLOAD ' "$directory/console.log" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | tail -n 1)"
    [[ -n "$payload_line" ]] || { fail_case "full guest printed no payload identity on $side"; return 1; }
    local rc=0
    e2fsck -fn "$directory/state.img" > "$directory/full-fn.log" 2>&1 || rc=$?
    (( rc == 0 )) || { fail_case "filesystem-full volume is not clean on $side (e2fsck $rc)"; return 1; }
    local state_word mounts_after
    state_word="$(superblock_state "$directory/state.img")"
    (( state_word & 1 )) || { fail_case "filesystem-full volume is not marked clean on $side (state $state_word)"; return 1; }
    mounts_after="$(superblock_mount_count "$directory/state.img")"
    (( mounts_after == mounts_before + 1 )) || {
        fail_case "$side filesystem-full mount count did not advance from $mounts_before to $mounts_after"
        return 1
    }
    local expected="${payload_line/STORAGE_PAYLOAD/STORAGE_VERIFY}"
    verify_payload "$side" "$base" "$directory/verify" "$base/witness" "$directory/state.img" "$expected" "$directory" || return 1
    record_transcript "$directory/verify" "$transcript"
    passed=$((passed + 1))
    note "storage full passed for $side"
}

run_unclean() {
    local side="$1" base="$2"
    local directory="$base/unclean"
    local transcript="$directory/transcript"
    mkdir -p "$directory"
    : > "$transcript"
    make_image "$directory/state.img" "$prepare_image_mib"
    inject_case "$directory" "$base/witness" stage-clean || { fail_case "could not stage the $side unclean guest"; return 1; }
    local mounts_before
    mounts_before="$(superblock_mount_count "$directory/state.img")"
    run_vm "$side" "$base" "$directory" "$directory/state.img" "STORAGE_READY" 900 || {
        fail_case "unclean guest did not reach its readiness marker on $side"
        return 1
    }
    record_transcript "$directory" "$transcript"
    require_console "$directory" "STORAGE_SYNCED" || return 1
    require_console "$directory" "STORAGE_READY" || return 1
    rg -q '^STORAGE_VMM_KILLED$' "$directory/runner.log" || {
        fail_case "unclean guest VMM was not killed on $side"
        return 1
    }
    local payload_line
    payload_line="$(rg '^STORAGE_PAYLOAD ' "$directory/console.log" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | tail -n 1)"
    [[ -n "$payload_line" ]] || { fail_case "unclean guest printed no payload identity on $side"; return 1; }
    local state_word mounts_after
    state_word="$(superblock_state "$directory/state.img")"
    (( (state_word & 1) == 0 )) || { fail_case "synced image is marked clean on $side (state $state_word)"; return 1; }
    mounts_after="$(superblock_mount_count "$directory/state.img")"
    (( mounts_after == mounts_before + 1 )) || {
        fail_case "$side unclean mount count did not advance from $mounts_before to $mounts_after"
        return 1
    }
    local rc=0
    e2fsck -fn "$directory/state.img" > "$directory/unclean-fn.log" 2>&1 || rc=$?
    (( rc == 0 )) || { fail_case "synced unclean image is not consistent on $side (e2fsck $rc)"; return 1; }
    local expected="${payload_line/STORAGE_PAYLOAD/STORAGE_VERIFY}"
    verify_payload "$side" "$base" "$directory/verify" "$base/witness" "$directory/state.img" "$expected" "$directory" || return 1
    record_transcript "$directory/verify" "$transcript"
    passed=$((passed + 1))
    note "storage unclean passed for $side"
}

run_corrupt() {
    local side="$1" base="$2"
    local directory="$base/corrupt"
    local transcript="$directory/transcript"
    mkdir -p "$directory"
    : > "$transcript"
    make_image "$directory/state.img" "$prepare_image_mib"
    inject_case "$directory" "$base/witness" prepare || { fail_case "could not stage the $side prepare guest"; return 1; }
    local mounts_before
    mounts_before="$(superblock_mount_count "$directory/state.img")"
    run_vm "$side" "$base" "$directory" "$directory/state.img" "" 900 || { fail_case "prepare guest failed on $side"; return 1; }
    record_transcript "$directory" "$transcript"
    require_console "$directory" "STORAGE_PREPARED" || return 1
    local rc=0
    e2fsck -fn "$directory/state.img" > "$directory/prepare-fn.log" 2>&1 || rc=$?
    (( rc == 0 )) || { fail_case "cleanly unmounted prepared image is not clean on $side (e2fsck $rc)"; return 1; }
    local state_word mounts_after
    state_word="$(superblock_state "$directory/state.img")"
    (( state_word & 1 )) || { fail_case "cleanly unmounted prepared image is not marked clean on $side (state $state_word)"; return 1; }
    mounts_after="$(superblock_mount_count "$directory/state.img")"
    (( mounts_after == mounts_before + 1 )) || {
        fail_case "$side prepared mount count did not advance from $mounts_before to $mounts_after"
        return 1
    }
    local payload_line
    payload_line="$(rg '^STORAGE_PAYLOAD ' "$directory/console.log" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | tail -n 1)"
    [[ -n "$payload_line" ]] || { fail_case "prepare guest printed no payload identity on $side"; return 1; }

    cp "$directory/state.img" "$directory/corrupt.img"
    local log_block_size first_data block_size group_table_offset
    log_block_size="$(od -An -tu4 -N4 -j $(( 1024 + 24 )) "$directory/corrupt.img" | tr -d ' ')"
    first_data="$(od -An -tu4 -N4 -j $(( 1024 + 20 )) "$directory/corrupt.img" | tr -d ' ')"
    block_size=$(( 1024 << log_block_size ))
    group_table_offset=$(( (first_data + 1) * block_size ))
    printf '\xff\xff\xff\xff' | dd of="$directory/corrupt.img" bs=1 seek=$(( group_table_offset + 4 )) conv=notrunc status=none

    local digest_before
    digest_before="$(image_digest "$directory/corrupt.img")"
    inject_case "$directory/corrupt-boot" "$base/witness" corrupt || { fail_case "could not stage the $side corrupt guest"; return 1; }
    run_vm "$side" "$base" "$directory/corrupt-boot" "$directory/corrupt.img" "" 900 || { fail_case "corrupt guest failed on $side"; return 1; }
    record_transcript "$directory/corrupt-boot" "$transcript"
    require_console "$directory/corrupt-boot" "STORAGE_CORRUPT_REFUSED" || {
        if rg -q 'STORAGE_CORRUPT_MOUNTED' "$directory/corrupt-boot/console.log"; then
            fail_case "corrupt image was silently mounted writable on $side"
        fi
        return 1
    }
    local digest_after
    digest_after="$(image_digest "$directory/corrupt.img")"
    [[ "$digest_after" == "$digest_before" ]] || { fail_case "corrupt mount attempt modified the image on $side"; return 1; }

    local class
    class="$(classify "$directory/corrupt.img" "$directory" corrupt)"
    printf '%s\n' "$class" > "$directory/classification"
    [[ "$class" != clean ]] || { fail_case "deliberately corrupted image was classified clean on $side"; return 1; }
    if [[ "$class" == repaired ]]; then
        local expected="${payload_line/STORAGE_PAYLOAD/STORAGE_VERIFY}"
        verify_payload "$side" "$base" "$directory/verify" "$base/witness" "$directory/corrupt-repair.img" "$expected" "$directory" || return 1
        record_transcript "$directory/verify" "$transcript"
    fi
    passed=$((passed + 1))
    note "storage corrupt passed for $side ($class)"
}

for side in "${backends[@]}"; do
    side_dir="$work/$side"
    mkdir -p "$side_dir"
    compile_witness "$side" "$side_dir/bin" || { fail_case "could not compile the storage witness for $side"; continue; }
    cp "$side_dir/bin/witness" "$side_dir/witness"
    if [[ "$side" != asterinas ]]; then
        run_cancellable "" bash "$repo_root/infra/asterinas/linux-reference.sh" "$linux_package" "$side_dir/linux-reference" || {
            fail_case "could not prepare the Linux reference for $side"
            continue
        }
    fi
    for case_name in "${cases[@]}"; do
        "run_$case_name" "$side" "$side_dir" || true
    done
done

if [[ "$backend" == both ]]; then
    for case_name in "${cases[@]}"; do
        [[ -s "$work/linux/$case_name/transcript" ]] || { fail_case "$case_name produced no Linux transcript"; continue; }
        normalize_transcript "$case_name" < "$work/linux/$case_name/transcript" > "$work/$case_name-linux.transcript"
        normalize_transcript "$case_name" < "$work/asterinas/$case_name/transcript" > "$work/$case_name-asterinas.transcript"
        if ! diff -u "$work/$case_name-linux.transcript" "$work/$case_name-asterinas.transcript" >&2; then
            fail_case "$case_name guest behavior differs between Linux and Asterinas"
        fi
    done
fi

if (( failed )); then
    printf 'qualification: storage failed; results kept in %s\n' "$work" >&2
    exit 1
fi
(( passed > 0 )) || { printf 'qualification: storage ran no case\n' >&2; exit 1; }
if [[ "${LAPUTA_STORAGE_KEEP:-0}" == 1 ]]; then
    printf 'qualification: storage evidence kept in %s\n' "$work"
else
    rm -rf -- "$work"
fi
printf 'qualification: storage passed %s cases for %s\n' "$passed" "$backend"
