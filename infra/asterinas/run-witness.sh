#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/run-cancellable.sh"
[[ $# == 3 ]] || {
    printf 'usage: run-witness.sh asterinas|linux WITNESS_SOURCE RESULT_DIR\n' >&2
    exit 2
}
backend="$1"
source_file="$(realpath "$2")"
result_dir="$3"
regression_root="$repo_root/asterinas/test/initramfs/src/regression"
[[ "$backend" == asterinas || "$backend" == linux ]] || { printf 'run-witness: unknown backend: %s\n' "$backend" >&2; exit 2; }
[[ "$source_file" == "$regression_root"/*.c ]] || [[ "$source_file" == "$regression_root"/*/*.c ]] || [[ "$source_file" == "$regression_root"/*/*/*.c ]] || {
    printf 'run-witness: the witness must be a C file under %s\n' "$regression_root" >&2
    exit 2
}

output="$repo_root/.out/asterinas-firecracker"
export TMPDIR="$repo_root/.work/tmp"
mkdir -p "$TMPDIR" "$result_dir"
result_dir="$(realpath "$result_dir")"
bundle="$(realpath "$output/current")"
dev_image="$(docker image inspect --format '{{.Id}}' "asterinas/dev:$(cat "$repo_root/asterinas/DOCKER_IMAGE_VERSION")")"
name="$(basename "$source_file" .c)"
memory_mib="$(jaq -r '."machine-config".mem_size_mib' "$bundle/firecracker.json")"

run_cancellable "" docker run --rm --pull never --platform linux/amd64 --network none --entrypoint /usr/bin/gcc \
    --mount "type=bind,src=$regression_root,dst=/regression,readonly" \
    --mount "type=bind,src=$result_dir,dst=/out" \
    "$dev_image" -Wall -Werror -static -pthread $([[ "$backend" != asterinas ]] || printf %s -D__asterinas__) -o /out/witness "/regression/${source_file#"$regression_root"/}"
printf '%s\n' "$name" > "$result_dir/witness.name"

if [[ "$backend" == asterinas ]]; then
    root="$(jaq -r '.drives[0].path_on_host' "$bundle/firecracker.json")"
    mkdir -p "$(dirname "$root")"
else
    root="$result_dir/root.ext2"
    run_cancellable "" bash "$repo_root/infra/asterinas/linux-reference.sh" \
        "${LAPUTA_LINUX_KERNEL_PACKAGE:-$output/linux-package.tar.gz}" "$result_dir/linux-reference"
fi
cp "$bundle/laputa-root.ext2" "$root"
chmod u+w "$root"
run_cancellable "" bash "$repo_root/infra/asterinas/inject-guest-file.sh" "$root" "$result_dir/witness" usr/lib/asterinas/witness "$dev_image" > /dev/null
run_cancellable "" bash "$repo_root/infra/asterinas/inject-guest-file.sh" "$root" "$result_dir/witness.name" usr/lib/asterinas/witness.name "$dev_image" > /dev/null

console="$result_dir/console.log"
status=0
if [[ "$backend" == asterinas ]]; then
    run_cancellable "" bash "$repo_root/infra/asterinas/run-test-vm.sh" "$output/bin/firecracker" "$bundle/firecracker.json" \
        "$console" "$console.firecracker" '' 1500 > "$result_dir/command.log" 2>&1 || status=$?
else
    XSH_MODULE_PATH="$repo_root" run_cancellable "" "$repo_root/.out/host/x86_64/xsh" "$repo_root/infra/asterinas/run-linux.xsh" -- \
        "$result_dir/linux-reference/linux-kernel" "$result_dir/linux-reference/linux-initramfs.cpio.gz" \
        "$root" "$console" "$console.qemu" '' 600 "$memory_mib" > "$result_dir/command.log" 2>&1 || status=$?
fi
sed 's/\x1b\[[0-9;]*m//g' "$console" | tr -d '\r' | rg 'WITNESS|summary|passed|failed|panic|NoMemory' | head -20 || true
if (( status == 0 )) && rg -q 'LAPUTA_ASTERINAS_WITNESS_OK' "$console" \
    && XSH_MODULE_PATH="$repo_root" "$repo_root/.out/host/x86_64/xsh" "$repo_root/infra/asterinas/check-guest-output.xsh" -- "$console" > "$result_dir/check.log" 2>&1; then
    printf 'run-witness: %s passed on %s\n' "$name" "$backend"
else
    printf 'run-witness: %s failed on %s; see %s and %s\n' "$name" "$backend" "$result_dir/command.log" "$result_dir/check.log" >&2
    exit 1
fi
