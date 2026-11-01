#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# == 4 ]] || {
    printf 'usage: run-guest-case.sh asterinas|linux CASE_DIR MODE RESULT_DIR\n' >&2
    exit 2
}
backend="$1"
case_dir="$(realpath "$2")"
mode="$3"
result_dir="$4"
[[ "$backend" == asterinas || "$backend" == linux ]] || { printf 'run-guest-case: unknown backend: %s\n' "$backend" >&2; exit 2; }
[[ -f "$case_dir/entry.xsh" ]] || { printf 'run-guest-case: %s has no entry.xsh\n' "$case_dir" >&2; exit 2; }
[[ "$mode" =~ ^[a-z0-9-]+$ ]] || { printf 'run-guest-case: invalid mode: %s\n' "$mode" >&2; exit 2; }

output="$repo_root/.out/asterinas-firecracker"
export TMPDIR="$repo_root/.work/tmp"
mkdir -p "$TMPDIR" "$result_dir"
result_dir="$(realpath "$result_dir")"
staged="$result_dir/case"
rm -rf "$staged"
mkdir -p "$staged"
cp -rL "$case_dir/." "$staged/"
bundle="$(realpath "$output/current")"
dev_image="$(docker image inspect --format '{{.Id}}' "asterinas/dev:$(cat "$repo_root/asterinas/DOCKER_IMAGE_VERSION")")"
memory_mib="$(jaq -r '."machine-config".mem_size_mib' "$bundle/firecracker.json")"

for source in "$staged"/*.c; do
    [[ -e "$source" ]] || continue
    docker run --rm --pull never --platform linux/amd64 --network none --entrypoint /usr/bin/gcc \
        --mount "type=bind,src=$staged,dst=/case" "$dev_image" \
        -Wall -O2 -static -o "/case/$(basename "$source" .c)" "/case/$(basename "$source")"
    rm -f "$source"
done
basename "$case_dir" > "$staged/name"
printf '%s\n' "$mode" > "$staged/mode"

firecracker_config="$bundle/firecracker.json"
if [[ "$backend" == asterinas ]]; then
    root="$result_dir/root.ext2"
    firecracker_config="$result_dir/firecracker.json"
    jaq --arg root "$root" '.drives[0].path_on_host = $root' "$bundle/firecracker.json" > "$firecracker_config"
else
    root="$result_dir/root.ext2"
    bash "$repo_root/infra/asterinas/linux-reference.sh" \
        "${LAPUTA_LINUX_KERNEL_PACKAGE:-$output/linux-package.tar.gz}" "$result_dir/linux-reference"
fi
cp "$bundle/laputa-root.ext2" "$root"
chmod u+w "$root"
for file in "$staged"/*; do
    bash "$repo_root/infra/asterinas/inject-guest-file.sh" "$root" "$file" "usr/lib/asterinas/case/$(basename "$file")" "$dev_image" > /dev/null
done

console="$result_dir/console.log"
status=0
timeout_seconds="${LAPUTA_CASE_TIMEOUT:-600}"
if [[ "$backend" == asterinas ]]; then
    bash "$repo_root/infra/asterinas/run-test-vm.sh" "$output/bin/firecracker" "$firecracker_config" \
        "$console" "$console.firecracker" '' "$(( timeout_seconds * 5 ))" > "$result_dir/command.log" 2>&1 || status=$?
else
    XSH_MODULE_PATH="$repo_root" "$repo_root/.out/host/x86_64/xsh" "$repo_root/infra/asterinas/run-linux.xsh" -- \
        "$result_dir/linux-reference/linux-kernel" "$result_dir/linux-reference/linux-initramfs.cpio.gz" \
        "$root" "$console" "$console.qemu" '' "$timeout_seconds" "$memory_mib" > "$result_dir/command.log" 2>&1 || status=$?
fi
sed 's/\x1b\[[0-9;]*m//g' "$console" | tr -d '\r' | rg 'CASE_|NTP_|FREQUENCY_|panic' | head -40 || true
if (( status == 0 )) && rg -q 'LAPUTA_ASTERINAS_CASE_OK' "$console"; then
    printf 'run-guest-case: %s %s passed on %s\n' "$(basename "$case_dir")" "$mode" "$backend"
else
    printf 'run-guest-case: %s %s failed on %s; see %s\n' "$(basename "$case_dir")" "$mode" "$backend" "$result_dir/command.log" >&2
    exit 1
fi
