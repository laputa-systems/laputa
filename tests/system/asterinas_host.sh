#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/laputa-asterinas-host.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

test_root="$scratch/clean-fixture"
mkdir -p "$test_root/infra/asterinas"
cp "$repo_root/infra/asterinas/clean.sh" "$test_root/infra/asterinas/clean.sh"
mkdir -p \
    "$test_root/.out/asterinas-firecracker/builds/test" \
    "$test_root/.cache/asterinas/source" \
    "$test_root/.out/artifacts/x86_64" \
    "$test_root/.out/world/x86_64" \
    "$test_root/.cache/sources/sha256"
printf 'backend output\n' > "$test_root/.out/asterinas-firecracker/builds/test/kernel.elf"
printf 'backend source\n' > "$test_root/.cache/asterinas/source/HEAD"
printf 'shared artifact\n' > "$test_root/.out/artifacts/x86_64/receipt.json"
printf 'shared plan\n' > "$test_root/.out/world/x86_64/plan.json"
printf 'shared source\n' > "$test_root/.cache/sources/sha256/input"
chmod -R a-w "$test_root/.out/asterinas-firecracker" "$test_root/.cache/asterinas"
bash "$test_root/infra/asterinas/clean.sh"
[[ ! -e "$test_root/.out/asterinas-firecracker" ]]
[[ ! -e "$test_root/.cache/asterinas" ]]
[[ "$(cat "$test_root/.out/artifacts/x86_64/receipt.json")" == 'shared artifact' ]]
[[ "$(cat "$test_root/.out/world/x86_64/plan.json")" == 'shared plan' ]]
[[ "$(cat "$test_root/.cache/sources/sha256/input")" == 'shared source' ]]

preflight_root="$scratch/preflight-fixture"
fake_bin="$preflight_root/bin"
mkdir -p "$preflight_root/infra/asterinas" "$fake_bin"
cp "$repo_root/infra/asterinas/preflight.sh" "$preflight_root/infra/asterinas/preflight.sh"
cp "$repo_root/infra/asterinas/inputs.lock" "$preflight_root/infra/asterinas/inputs.lock"
for tool in awk cat cc find git make readelf sha256sum sort; do
    cat > "$fake_bin/$tool" <<'TOOL'
#!/usr/bin/env bash
exit 0
TOOL
    chmod 755 "$fake_bin/$tool"
done
cat > "$fake_bin/uname" <<'UNAME'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf '%s\n' "$FAKE_UNAME_SYSTEM" ;;
    -m) printf '%s\n' "$FAKE_UNAME_MACHINE" ;;
    *) exit 2 ;;
esac
UNAME
cat > "$fake_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'called\n' > "$ASTERINAS_TEST_DOCKER_MARKER"
exit 1
DOCKER
chmod 755 "$fake_bin/uname" "$fake_bin/docker"

assert_preflight_rejects_host() {
    local system="$1"
    local machine="$2"
    local expected="$3"
    local log="$scratch/preflight-$system-$machine.log"
    local docker_marker="$scratch/docker-called"

    if PATH="$fake_bin:$PATH" \
        FAKE_UNAME_SYSTEM="$system" \
        FAKE_UNAME_MACHINE="$machine" \
        ASTERINAS_TEST_DOCKER_MARKER="$docker_marker" \
        bash "$preflight_root/infra/asterinas/preflight.sh" > "$log" 2>&1; then
        printf 'preflight unexpectedly accepted %s %s\n' "$system" "$machine" >&2
        exit 1
    fi
    grep -Fq "$expected" "$log" || {
        cat "$log" >&2
        printf 'preflight did not report the expected host failure: %s\n' "$expected" >&2
        exit 1
    }
    [[ ! -e "$docker_marker" ]]
}

assert_preflight_rejects_host Darwin x86_64 'Firecracker requires a Linux host'
assert_preflight_rejects_host Linux aarch64 'Firecracker requires x86_64, found aarch64'
printf 'Asterinas host checks passed.\n'
