#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# == 5 ]] || {
    printf 'usage: native-batches.sh asterinas|linux MODULES_FILE BATCH_SIZE BUDGET_SECONDS RESULT_DIR\n' >&2
    exit 2
}
backend="$1"
modules_file="$2"
batch_size="$3"
budget_seconds="$4"
result_dir="$5"
[[ "$backend" == asterinas || "$backend" == linux ]] || { printf 'native-batches: unknown backend: %s\n' "$backend" >&2; exit 2; }
[[ -s "$modules_file" ]] || { printf 'native-batches: module list is missing or empty: %s\n' "$modules_file" >&2; exit 2; }
[[ "$batch_size" =~ ^[1-9][0-9]*$ && "$budget_seconds" =~ ^[1-9][0-9]*$ ]] || { printf 'native-batches: batch size and budget must be positive integers\n' >&2; exit 2; }

output="$repo_root/.out/asterinas-firecracker"
export TMPDIR="$repo_root/.work/tmp"
mkdir -p "$TMPDIR" "$result_dir"
result_dir="$(realpath "$result_dir")"
[[ ! -e "$result_dir/batches.tsv" ]] || { printf 'native-batches: result directory already holds a run: %s\n' "$result_dir" >&2; exit 2; }
bundle="$(realpath "$output/current")"
dev_image="$(docker image inspect --format '{{.Id}}' "asterinas/dev:$(cat "$repo_root/asterinas/DOCKER_IMAGE_VERSION")")"
runtime_root="$result_dir/root.ext2"
if [[ "$backend" == asterinas ]]; then
    runtime_root="$(jaq -r '.drives[0].path_on_host' "$bundle/firecracker.json")"
else
    bash "$repo_root/infra/asterinas/linux-reference.sh" \
        "${LAPUTA_LINUX_KERNEL_PACKAGE:-$output/linux-package.tar.gz}" "$result_dir/linux-reference"
fi

mapfile -t pending < "$modules_file"
: > "$result_dir/interrupted.txt"
deadline=$(( $(date +%s) + budget_seconds ))
batch=0
while (( ${#pending[@]} > 0 )); do
    if (( $(date +%s) >= deadline )); then
        printf 'native-batches: budget reached with %d modules unstarted\n' "${#pending[@]}" >&2
        break
    fi
    batch=$((batch + 1))
    take=$(( batch_size < ${#pending[@]} ? batch_size : ${#pending[@]} ))
    batch_modules=("${pending[@]:0:$take}")
    printf '%s\n' "${batch_modules[@]}" > "$result_dir/$batch.modules"
    selection="${batch_modules[*]}"
    console="$result_dir/$batch.console.log"
    cp "$bundle/laputa-root.ext2" "$runtime_root"
    chmod u+w "$runtime_root"
    bash "$repo_root/infra/asterinas/inject-xsh-test-selection.sh" "$runtime_root" "$result_dir/$batch.modules" "$dev_image" > /dev/null
    started_at=$(date +%s)
    status=0
    if [[ "$backend" == asterinas ]]; then
        polls=$(( 1500 * take ))
        (( polls <= 15000 )) || polls=15000
        bash "$repo_root/infra/asterinas/run-test-vm.sh" "$output/bin/firecracker" "$bundle/firecracker.json" \
            "$console" "$console.firecracker" "$selection" "$polls" > "$console.command" 2>&1 || status=$?
    else
        XSH_MODULE_PATH="$repo_root" "$repo_root/.out/host/x86_64/xsh" "$repo_root/infra/asterinas/run-linux.xsh" -- \
            "$result_dir/linux-reference/linux-kernel" "$result_dir/linux-reference/linux-initramfs.cpio.gz" \
            "$runtime_root" "$console" "$console.qemu" "$selection" 3000 > "$console.command" 2>&1 || status=$?
    fi
    printf '%s\t%s\t%s\t%s\n' "$batch" "$take" "$status" "$(( $(date +%s) - started_at ))" >> "$result_dir/batches.tsv"
    sed 's/\x1b\[[0-9;]*m//g' "$console" | tr -d '\r' > "$console.plain"
    sed -n 's/^LAPUTA_ASTERINAS_XSH_TEST_START //p' "$console.plain" > "$result_dir/$batch.started"
    mapfile -t started < "$result_dir/$batch.started"
    if (( ${#started[@]} == 0 )); then
        printf 'native-batches: batch %d started no module; see %s\n' "$batch" "$console.command" >&2
        exit 1
    fi
    if ! rg -q '^LAPUTA_ASTERINAS_TEST_(OK|FAILED xsh-test)' "$console.plain"; then
        last="${started[-1]}"
        unset 'started[-1]'
        if (( ${#started[@]} == 0 )); then
            printf '%s\n' "$last" >> "$result_dir/interrupted.txt"
            started=("$last")
        fi
    fi
    next=()
    for module in "${pending[@]}"; do
        found=false
        for done_module in "${started[@]}"; do
            [[ "$module" != "$done_module" ]] || { found=true; break; }
        done
        [[ "$found" == true ]] || next+=("$module")
    done
    pending=("${next[@]}")
done
printf '%s\n' "${pending[@]}" > "$result_dir/unstarted.txt"
rm -f "$result_dir"/*.console.log.plain
