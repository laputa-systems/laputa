#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/inputs.lock"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/laputa-asterinas-host.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

test_root="$scratch/clean-fixture"
fake_bin="$scratch/clean-bin"
clean_image_log="$scratch/clean-images.log"
mkdir -p "$test_root/infra/asterinas"
mkdir -p "$fake_bin"
cp "$repo_root/infra/asterinas/clean.sh" "$test_root/infra/asterinas/clean.sh"
cp "$repo_root/infra/asterinas/inputs.lock" "$test_root/infra/asterinas/inputs.lock"
mkdir -p \
    "$test_root/.out/asterinas-firecracker/builds/test" \
    "$test_root/.cache/asterinas/source" \
    "$test_root/.out/artifacts/x86_64" \
    "$test_root/.out/world/x86_64" \
    "$test_root/.cache/sources/sha256" \
    "$test_root/target/laputa"
printf 'backend output\n' > "$test_root/.out/asterinas-firecracker/builds/test/kernel.elf"
printf 'backend source\n' > "$test_root/.cache/asterinas/source/HEAD"
printf 'shared artifact\n' > "$test_root/.out/artifacts/x86_64/receipt.json"
printf 'shared plan\n' > "$test_root/.out/world/x86_64/plan.json"
printf 'shared source\n' > "$test_root/.cache/sources/sha256/input"
printf 'profile output\n' > "$test_root/target/laputa/profile.img"
cat > "$fake_bin/make" <<'MAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -C && "$2" == "$ASTERINAS_TEST_REPO" && "$3" == distclean ]]
rm -rf -- "$2/.out" "$2/target" "$2/.cache"
MAKE
cat > "$fake_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == image ]]
case "$2" in
    inspect)
        [[ "$3" == xsh-test || "$3" == "asterinas/dev:$ASTERINAS_TEST_DEV_IMAGE" ]]
        ;;
    rm)
        [[ "$3" == --force && ( "$4" == xsh-test || "$4" == "asterinas/dev:$ASTERINAS_TEST_DEV_IMAGE" ) ]]
        printf '%s\n' "$*" >> "$ASTERINAS_TEST_DOCKER_LOG"
        ;;
    *) exit 2 ;;
esac
DOCKER
chmod 755 "$fake_bin/make" "$fake_bin/docker"
ASTERINAS_TEST_REPO="$test_root" PATH="$fake_bin:$PATH" \
ASTERINAS_TEST_DOCKER_LOG="$clean_image_log" \
ASTERINAS_TEST_DEV_IMAGE="$ASTERINAS_DEV_IMAGE_VERSION" \
    bash "$test_root/infra/asterinas/clean.sh"
[[ ! -e "$test_root/.out" ]]
[[ ! -e "$test_root/target" ]]
[[ ! -e "$test_root/.cache" ]]
expected_clean_images="image rm --force xsh-test
image rm --force asterinas/dev:$ASTERINAS_DEV_IMAGE_VERSION"
[[ "$(cat "$clean_image_log")" == "$expected_clean_images" ]]

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

xsh_root="$scratch/xsh-snapshot"
xsh_output="$scratch/xsh-output"
mkdir -p "$xsh_root/tests/xsh/stdlib" "$xsh_root/docs"
printf 'test selected_module { assert true }\n' > "$xsh_root/tests/xsh/stdlib/fs.xsh"
printf 'XSH specification fixture\n' > "$xsh_root/docs/SPEC.md"
readarray -t staged_xsh_test < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" tests/xsh/stdlib/fs.xsh "$xsh_output"
)
[[ ${#staged_xsh_test[@]} == 3 ]]
[[ "${staged_xsh_test[0]}" == "$xsh_output/xsh-test-overlay" ]]
[[ "${staged_xsh_test[1]}" == tests/xsh/stdlib/fs.xsh ]]
[[ "${staged_xsh_test[2]}" == "$(sha256_file "$xsh_root/tests/xsh/stdlib/fs.xsh")" ]]
[[ -f "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source/tests/xsh/stdlib/fs.xsh" ]]
[[ -f "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source/docs/SPEC.md" ]]
[[ ! -e "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source/.git" ]]
grep -Fq 'profile": "asterinas-viability-xsh-test"' "$xsh_output/xsh-test-overlay/overlay.json"
[[ "$(cat "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-test.path")" == tests/xsh/stdlib/fs.xsh ]]
initial_test_sha256="${staged_xsh_test[2]}"
printf 'test selected_module { assert 42 == 42 }\n' > "$xsh_root/tests/xsh/stdlib/fs.xsh"
readarray -t changed_xsh_test < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" tests/xsh/stdlib/fs.xsh "$xsh_output"
)
[[ ${changed_xsh_test[2]} == "$(sha256_file "$xsh_root/tests/xsh/stdlib/fs.xsh")" ]]
[[ ${changed_xsh_test[2]} != "$initial_test_sha256" ]]
cmp "$xsh_root/tests/xsh/stdlib/fs.xsh" \
    "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source/tests/xsh/stdlib/fs.xsh"

ln -s "$scratch/outside-test.xsh" "$xsh_root/tests/xsh/stdlib/escape.xsh"
printf 'outside\n' > "$scratch/outside-test.xsh"
before_invalid_stage="$(sha256_file "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-test.path")"
assert_xsh_test_rejected() {
    local module="$1"
    local log="$scratch/xsh-stage-rejected.log"
    if bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" "$module" "$xsh_output" > "$log" 2>&1; then
        printf 'XSH test staging unexpectedly accepted %s\n' "$module" >&2
        exit 1
    fi
    [[ -s "$log" ]]
    [[ "$(sha256_file "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-test.path")" == "$before_invalid_stage" ]]
}
assert_xsh_test_rejected ../tests/xsh/stdlib/fs.xsh
assert_xsh_test_rejected tests/xsh/stdlib/escape.xsh
assert_xsh_test_rejected tests/xsh/stdlib/missing.xsh

vm_test_root="$scratch/vm-fixture"
fake_firecracker="$vm_test_root/firecracker"
mkdir -p "$vm_test_root"
cat > "$fake_firecracker" <<'FIRECRACKER'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FAKE_FIRECRACKER_PID_FILE"
case "$FAKE_FIRECRACKER_MODE" in
    base|success)
        printf '%s\n' \
            LAPUTA_ASTERINAS_EXT2_MOUNT_OK \
            LAPUTA_ASTERINAS_SWITCH_ROOT_START \
            LAPUTA_ASTERINAS_BOOT_SETUP_OK \
            LAPUTA_ASTERINAS_XINIT_PID1_OK \
            LAPUTA_ASTERINAS_ROOTFS_OK \
            LAPUTA_ASTERINAS_LOOPBACK_OK \
            LAPUTA_ASTERINAS_XSH_OK
        if [[ "$FAKE_FIRECRACKER_MODE" == success ]]; then
            printf '%s\n' \
                'LAPUTA_ASTERINAS_XSH_TEST_START tests/xsh/stdlib/numeric.xsh' \
                LAPUTA_ASTERINAS_XSH_TEST_OK
        fi
        printf '%s\n' LAPUTA_ASTERINAS_TEST_OK
        exec /bin/sleep 30
        ;;
    failed)
        printf '%s\n' 'LAPUTA_ASTERINAS_TEST_FAILED proof: expected failure'
        exec /bin/sleep 30
        ;;
    panic)
        printf '%s\n' 'Kernel panic: expected failure'
        exec /bin/sleep 30
        ;;
    early)
        exit 0
        ;;
    timeout)
        exec /bin/sleep 30
        ;;
    *) exit 2 ;;
esac
FIRECRACKER
chmod 755 "$fake_firecracker"

assert_vm_case() {
    local mode="$1"
    local selected_module="$2"
    local max_polls="$3"
    local expected_status="$4"
    local pid_file="$vm_test_root/$mode.pid"
    local console_log="$vm_test_root/$mode-console.log"
    local firecracker_log="$vm_test_root/$mode-firecracker.log"
    local status=0

    if FAKE_FIRECRACKER_MODE="$mode" \
        FAKE_FIRECRACKER_PID_FILE="$pid_file" \
        bash "$repo_root/infra/asterinas/run-test-vm.sh" \
            "$fake_firecracker" "$vm_test_root/config.json" "$console_log" "$firecracker_log" \
            "$selected_module" "$max_polls" > "$vm_test_root/$mode-run.log" 2>&1; then
        status=0
    else
        status=$?
    fi
    [[ "$status" == "$expected_status" ]] || {
        cat "$vm_test_root/$mode-run.log" >&2
        printf 'VM runner %s case returned %s, expected %s\n' "$mode" "$status" "$expected_status" >&2
        exit 1
    }
    if [[ -f "$pid_file" ]]; then
        local pid
        pid="$(cat "$pid_file")"
        if kill -0 "$pid" 2>/dev/null; then
            printf 'VM runner left fake Firecracker running in %s case (pid %s)\n' "$mode" "$pid" >&2
            exit 1
        fi
    fi
}

assert_vm_case base '' 2 0
assert_vm_case success tests/xsh/stdlib/numeric.xsh 2 0
assert_vm_case base tests/xsh/stdlib/numeric.xsh 2 1
assert_vm_case failed '' 2 1
assert_vm_case panic '' 2 1
assert_vm_case early '' 2 1
assert_vm_case timeout '' 3 1
if bash "$repo_root/infra/asterinas/run-test-vm.sh" \
    "$vm_test_root/missing-firecracker" "$vm_test_root/config.json" \
    "$vm_test_root/missing-console.log" "$vm_test_root/missing-firecracker.log" '' 2 \
    > "$vm_test_root/missing-firecracker-run.log" 2>&1; then
    printf 'VM runner unexpectedly accepted a missing Firecracker executable\n' >&2
    exit 1
fi
grep -Fq 'Firecracker is not executable' "$vm_test_root/missing-firecracker-run.log"
printf 'Asterinas host checks passed.\n'
