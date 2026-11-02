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
    if [[ "${LAPUTA_GUEST_NETWORK:-}" == tap ]]; then
        jaq '.["network-interfaces"] = [{iface_id: "eth0", host_dev_name: "tap0", guest_mac: "AA:FC:00:00:00:01"}]' \
            "$firecracker_config" > "$firecracker_config.tmp" && mv "$firecracker_config.tmp" "$firecracker_config"
    fi
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
    vm_command=(bash "$repo_root/infra/asterinas/run-test-vm.sh" "$output/bin/firecracker" "$firecracker_config"
        "$console" "$console.firecracker" '' "$(( timeout_seconds * 5 ))")
else
    vm_command=("$repo_root/.out/host/x86_64/xsh" "$repo_root/infra/asterinas/run-linux.xsh" --
        "$result_dir/linux-reference/linux-kernel" "$result_dir/linux-reference/linux-initramfs.cpio.gz"
        "$root" "$console" "$console.qemu" '' "$timeout_seconds" "$memory_mib")
fi
if [[ "${LAPUTA_GUEST_NETWORK:-}" == tap ]]; then
    [[ "$backend" == asterinas ]] || vm_command+=(--tap tap0)
    control_environment=()
    if [[ -x "$case_dir/vmm-control.sh" ]]; then
        [[ "$backend" == asterinas ]] || vm_command+=(--qmp /run/laputa-vmm.sock)
        control_environment=(--env LAPUTA_VMM_CONTROL=/run/laputa-vmm.sock --env "LAPUTA_PEER_BACKEND=$backend" --env "LAPUTA_PEER_REPO=$repo_root")
    fi
    peer_command=:
    peer_environment=()
    if [[ -x "$case_dir/peer.sh" ]]; then
        snapshot_name="$(jaq -r '.xsh.commit + "-" + .xsh.build_inputs_sha256' "$bundle/manifest.json")"
        snapshot="$output/xsh-snapshots/$snapshot_name"
        [[ -d "$snapshot/core" ]] || { printf 'run-guest-case: no XSH snapshot %s\n' "$snapshot" >&2; exit 1; }
        peer_command='bash "$LAPUTA_PEER_DIR/peer.sh" "$LAPUTA_PEER_MODE" "$LAPUTA_PEER_DIR" > "$LAPUTA_PEER_DIR/peer.log" 2>&1 &'
        peer_environment=(--env "LAPUTA_PEER_DIR=$staged" --env "LAPUTA_PEER_MODE=$mode"
            --env "LAPUTA_PEER_XSH=$repo_root/.out/host/x86_64/xsh" --env "LAPUTA_PEER_CORE=$snapshot/core")
    fi
    vm_command=(docker run --rm --init --pull never --platform linux/amd64 --network none
        --cap-add NET_ADMIN --device /dev/net/tun --device /dev/kvm
        --mount "type=bind,src=$repo_root,dst=$repo_root"
        --env "XSH_MODULE_PATH=$repo_root" --env QEMU_SYSTEM_X86_64=/usr/local/qemu/bin/qemu-system-x86_64
        "${peer_environment[@]}" "${control_environment[@]}"
        --workdir "$repo_root" --entrypoint /bin/bash "$dev_image" -c
        "set -e
ip tuntap add dev tap0 mode tap
ip addr add 192.0.2.1/24 dev tap0
ip link set tap0 up
$peer_command"'
exec "$@"'
        _ "${vm_command[@]}")
else
    [[ "$backend" == asterinas ]] || vm_command=(env "XSH_MODULE_PATH=$repo_root" "${vm_command[@]}")
fi
"${vm_command[@]}" > "$result_dir/command.log" 2>&1 || status=$?
sed 's/\x1b\[[0-9;]*m//g' "$console" | tr -d '\r' | rg 'CASE_|NTP_|FREQUENCY_|NET_|panic' | head -40 || true
if (( status == 0 )) && rg -q 'LAPUTA_ASTERINAS_CASE_OK' "$console"; then
    printf 'run-guest-case: %s %s passed on %s\n' "$(basename "$case_dir")" "$mode" "$backend"
else
    printf 'run-guest-case: %s %s failed on %s; see %s\n' "$(basename "$case_dir")" "$mode" "$backend" "$result_dir/command.log" >&2
    exit 1
fi
