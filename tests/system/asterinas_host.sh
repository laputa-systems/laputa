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
mkdir -p "$xsh_root/tests/xsh/stdlib" "$xsh_root/docs" \
    "$xsh_root/core/tests" "$xsh_root/dev/tests" "$xsh_root/showcase/tests"
printf 'test selected_module { assert true }\n' > "$xsh_root/tests/xsh/stdlib/fs.xsh"
printf 'XSH specification fixture\n' > "$xsh_root/docs/SPEC.md"
printf 'module_path = .\ntest_roots = core/tests\n  dev/tests\n  tests\n  showcase/tests\n' > "$xsh_root/xsht-config.ini"
printf 'test core_suite_fixture { assert true }\n' > "$xsh_root/core/tests/test-core.xsh"
printf 'test dev_suite_fixture { assert true }\n' > "$xsh_root/dev/tests/test-dev.xsh"
printf 'test showcase_suite_fixture { assert true }\n' > "$xsh_root/showcase/tests/test-showcase.xsh"
git -C "$xsh_root" init -q
git -C "$xsh_root" config user.email asterinas-test@example.invalid
git -C "$xsh_root" config user.name Asterinas
git -C "$xsh_root" add tests docs core dev showcase xsht-config.ini
git -C "$xsh_root" commit -qm initial
readarray -t staged_xsh_test < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" tests/xsh/stdlib/fs.xsh "$xsh_output"
)
[[ ${#staged_xsh_test[@]} == 3 ]]
[[ "${staged_xsh_test[0]}" == "$xsh_output/xsh-test-overlay" ]]
[[ "${staged_xsh_test[1]}" == tests/xsh/stdlib/fs.xsh ]]
initial_test_sha256="$(git -C "$xsh_root" archive --format=tar HEAD | sha256sum | awk '{print $1}')"
[[ "${staged_xsh_test[2]}" == "$initial_test_sha256" ]]
[[ -f "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source/tests/xsh/stdlib/fs.xsh" ]]
[[ -f "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source/docs/SPEC.md" ]]
[[ ! -e "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source/.git" ]]
grep -Fq 'profile": "asterinas-viability-xsh-test"' "$xsh_output/xsh-test-overlay/overlay.json"
[[ "$(cat "$xsh_output/xsh-test.selection")" == tests/xsh/stdlib/fs.xsh ]]
printf 'test selected_module { assert 42 == 42 }\n' > "$xsh_root/tests/xsh/stdlib/fs.xsh"
git -C "$xsh_root" add tests/xsh/stdlib/fs.xsh
git -C "$xsh_root" commit -qm 'change selected XSH test'
readarray -t changed_xsh_test < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" tests/xsh/stdlib/fs.xsh "$xsh_output"
)
[[ ${changed_xsh_test[2]} == "$(git -C "$xsh_root" archive --format=tar HEAD | sha256sum | awk '{print $1}')" ]]
[[ ${changed_xsh_test[2]} != "$initial_test_sha256" ]]
cmp "$xsh_root/tests/xsh/stdlib/fs.xsh" \
    "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source/tests/xsh/stdlib/fs.xsh"
readarray -t staged_core_test < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" core/tests/test-core.xsh "$xsh_output"
)
[[ "${staged_core_test[1]}" == core/tests/test-core.xsh ]]
[[ -f "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source/core/tests/test-core.xsh" ]]
readarray -t staged_exact_xsh_test < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" core/tests/test-core.xsh::core_suite_fixture "$xsh_output"
)
[[ "${staged_exact_xsh_test[1]}" == core/tests/test-core.xsh::core_suite_fixture ]]
[[ "$(cat "$xsh_output/xsh-test.selection")" == core/tests/test-core.xsh::core_suite_fixture ]]
[[ ! -e "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-test.selection" ]]
readarray -t staged_batch < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" "core/tests/test-core.xsh  tests/xsh/stdlib/fs.xsh" "$xsh_output"
)
[[ "${staged_batch[1]}" == 'core/tests/test-core.xsh tests/xsh/stdlib/fs.xsh' ]]
[[ "$(cat "$xsh_output/xsh-test.selection")" == $'core/tests/test-core.xsh\ntests/xsh/stdlib/fs.xsh' ]]

ln -s "$scratch/outside-test.xsh" "$xsh_root/tests/xsh/stdlib/escape.xsh"
printf 'outside\n' > "$scratch/outside-test.xsh"
before_invalid_stage="$(sha256_file "$xsh_output/xsh-test.selection")"
assert_xsh_test_rejected() {
    local module="$1"
    local log="$scratch/xsh-stage-rejected.log"
    if bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" "$module" "$xsh_output" > "$log" 2>&1; then
        printf 'XSH test staging unexpectedly accepted %s\n' "$module" >&2
        exit 1
    fi
    [[ -s "$log" ]]
    [[ "$(sha256_file "$xsh_output/xsh-test.selection")" == "$before_invalid_stage" ]]
}
assert_xsh_test_rejected ../tests/xsh/stdlib/fs.xsh
assert_xsh_test_rejected core/tests/../../tests/xsh/stdlib/fs.xsh
assert_xsh_test_rejected tests/xsh/stdlib/escape.xsh
assert_xsh_test_rejected tests/xsh/stdlib/missing.xsh
assert_xsh_test_rejected 'core/tests/test-core.xsh tests/xsh/stdlib/missing.xsh'
assert_xsh_test_rejected 'all core/tests/test-core.xsh'
assert_xsh_test_rejected ''

readarray -t staged_full_xsh_suite < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" all "$xsh_output"
)
[[ ${#staged_full_xsh_suite[@]} == 3 ]]
[[ "${staged_full_xsh_suite[1]}" == all ]]
[[ "${staged_full_xsh_suite[2]}" == "$(git -C "$xsh_root" archive --format=tar HEAD | sha256sum | awk '{print $1}')" ]]
full_suite_source="$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-source"
[[ -f "$full_suite_source/xsht-config.ini" ]]
[[ -f "$full_suite_source/core/tests/test-core.xsh" ]]
[[ -f "$full_suite_source/dev/tests/test-dev.xsh" ]]
[[ -f "$full_suite_source/tests/xsh/stdlib/fs.xsh" ]]
[[ -f "$full_suite_source/showcase/tests/test-showcase.xsh" ]]
[[ ! -e "$full_suite_source/.git" ]]
[[ ! -e "$full_suite_source/.envrc" ]]
initial_full_suite_sha256="${staged_full_xsh_suite[2]}"
printf 'test dev_suite_fixture { assert 42 == 42 }\n' > "$xsh_root/dev/tests/test-dev.xsh"
git -C "$xsh_root" add dev/tests/test-dev.xsh
git -C "$xsh_root" commit -qm 'change full XSH suite input'
readarray -t changed_full_xsh_suite < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" all "$xsh_output"
)
[[ "${changed_full_xsh_suite[2]}" == "$(git -C "$xsh_root" archive --format=tar HEAD | sha256sum | awk '{print $1}')" ]]
[[ "${changed_full_xsh_suite[2]}" != "$initial_full_suite_sha256" ]]

cargo_digest() { bash "$repo_root/infra/asterinas/cargo-input-digest.sh" "$1"; }
for cargo_dir in "$scratch/cargo-first/kernel" "$scratch/cargo-second/another-name"; do
    mkdir -p "$cargo_dir/osdk" "$cargo_dir/.cargo"
    printf 'lock\n' > "$cargo_dir/Cargo.lock"
    printf 'osdk lock\n' > "$cargo_dir/osdk/Cargo.lock"
    printf 'registry\n' > "$cargo_dir/.cargo/config.toml"
done
[[ "$(cargo_digest "$scratch/cargo-first/kernel")" == "$(cargo_digest "$scratch/cargo-second/another-name")" ]] || {
    printf 'the Cargo input digest depends on where the source is checked out\n' >&2
    exit 1
}
for cargo_file in Cargo.lock osdk/Cargo.lock .cargo/config.toml; do
    cp -r "$scratch/cargo-second/another-name" "$scratch/cargo-changed"
    printf 'changed\n' >> "$scratch/cargo-changed/$cargo_file"
    [[ "$(cargo_digest "$scratch/cargo-changed")" != "$(cargo_digest "$scratch/cargo-first/kernel")" ]] || {
        printf 'the Cargo input digest ignores %s\n' "$cargo_file" >&2
        exit 1
    }
    rm -rf "$scratch/cargo-changed"
done

kernel_origin="$scratch/kernel-origin"
kernel_fixture="$scratch/kernel-fixture"
real_git="$(command -v git)"
no_submodule_bin="$scratch/no-submodule-bin"
mkdir -p "$no_submodule_bin" "$kernel_origin" "$kernel_fixture/infra/asterinas"
cat > "$no_submodule_bin/git" <<GIT
#!/usr/bin/env bash
for argument in "\$@"; do
    [[ "\$argument" != submodule ]] || { printf "git: 'submodule' is not a git command\\n" >&2; exit 1; }
done
exec "$real_git" "\$@"
GIT
chmod 755 "$no_submodule_bin/git"
cp "$repo_root/infra/asterinas/checkout-kernel.sh" "$kernel_fixture/infra/asterinas/"
git -C "$kernel_origin" init -q
git -C "$kernel_origin" config user.email asterinas-test@example.invalid
git -C "$kernel_origin" config user.name Asterinas
printf 'first\n' > "$kernel_origin/kernel.txt"
git -C "$kernel_origin" add kernel.txt
git -C "$kernel_origin" commit -qm first
first_kernel="$(git -C "$kernel_origin" rev-parse HEAD)"
git -C "$kernel_fixture" init -q
printf '[submodule "asterinas"]\n\tpath = asterinas\n\turl = %s\n' "$kernel_origin" > "$kernel_fixture/.gitmodules"
git -C "$kernel_fixture" update-index --add --cacheinfo "160000,$first_kernel,asterinas"
checkout_kernel() { PATH="$no_submodule_bin:$PATH" bash "$kernel_fixture/infra/asterinas/checkout-kernel.sh"; }
checkout_kernel
[[ "$(git -C "$kernel_fixture/asterinas" rev-parse HEAD)" == "$first_kernel" ]]
[[ -f "$kernel_fixture/asterinas/.git" ]]
[[ "$(git -C "$kernel_fixture/asterinas" remote get-url origin)" == "$kernel_origin" ]]
checkout_kernel
printf 'second\n' > "$kernel_origin/kernel.txt"
git -C "$kernel_origin" commit -qam second
second_kernel="$(git -C "$kernel_origin" rev-parse HEAD)"
git -C "$kernel_fixture" update-index --cacheinfo "160000,$second_kernel,asterinas"
checkout_kernel
[[ "$(git -C "$kernel_fixture/asterinas" rev-parse HEAD)" == "$second_kernel" ]]
[[ "$(cat "$kernel_fixture/asterinas/kernel.txt")" == second ]]
git -C "$kernel_fixture" update-index --force-remove asterinas
rm -rf "$kernel_fixture/asterinas"
mkdir "$kernel_fixture/asterinas"
printf 'stray\n' > "$kernel_fixture/asterinas/stray.txt"
git -C "$kernel_fixture" update-index --add --cacheinfo "160000,$second_kernel,asterinas"
if checkout_kernel > "$scratch/kernel-stray.log" 2>&1; then
    printf 'kernel checkout overwrote a directory that is not a checkout\n' >&2
    exit 1
fi
rg -q 'not a git checkout' "$scratch/kernel-stray.log"

published_root="$scratch/published-fixture"
published_kernel="$scratch/published-kernel"
published_xsh="$scratch/published-xsh"
mkdir -p "$published_root/infra/asterinas" "$published_kernel" "$published_xsh"
cp "$repo_root/infra/asterinas/published-inputs.sh" "$published_root/infra/asterinas/"
for published_origin in "$published_kernel" "$published_xsh"; do
    git -C "$published_origin" init -q
    git -C "$published_origin" config user.email asterinas-test@example.invalid
    git -C "$published_origin" config user.name Asterinas
done
printf '1.2.3\n' > "$published_kernel/DOCKER_IMAGE_VERSION"
git -C "$published_kernel" add DOCKER_IMAGE_VERSION
git -C "$published_kernel" commit -qm kernel
printf 'FROM scratch\n' > "$published_xsh/Dockerfile.test"
git -C "$published_xsh" add Dockerfile.test
git -C "$published_xsh" commit -qm xsh
published_kernel_commit="$(git -C "$published_kernel" rev-parse HEAD)"
published_xsh_commit="$(git -C "$published_xsh" rev-parse HEAD)"
git -C "$published_root" init -q
write_published_lock() {
    printf 'ASTERINAS_REPOSITORY=%s\nASTERINAS_COMMIT=%s\nASTERINAS_DEV_IMAGE_VERSION=1.2.3\nXSH_REPOSITORY=%s\nXSH_COMMIT=%s\n' \
        "$published_kernel" "$1" "$published_xsh" "$2" > "$published_root/infra/asterinas/inputs.lock"
}
write_published_lock "$published_kernel_commit" "$published_xsh_commit"
git -C "$published_root" update-index --add --cacheinfo "160000,$published_kernel_commit,asterinas"
run_published_inputs() { bash "$published_root/infra/asterinas/published-inputs.sh"; }
run_published_inputs > "$scratch/published-ok.log" 2>&1 || { cat "$scratch/published-ok.log" >&2; printf 'published inputs rejected matching pins\n' >&2; exit 1; }
rg -q "match the lock" "$scratch/published-ok.log"
compgen -G "$published_root/.work/tmp/published-inputs.*" > /dev/null && { printf 'published inputs left its fresh caches\n' >&2; exit 1; }

printf 'unpublished\n' > "$published_kernel/unpublished.txt"
git -C "$published_kernel" add unpublished.txt
git -C "$published_kernel" commit -qm unpublished
unpublished_commit="$(git -C "$published_kernel" rev-parse HEAD)"
git -C "$published_kernel" reset -q --hard "$published_kernel_commit"
git -C "$published_kernel" reflog expire --expire=now --all
git -C "$published_kernel" gc -q --prune=now
write_published_lock "$unpublished_commit" "$published_xsh_commit"
git -C "$published_root" update-index --cacheinfo "160000,$unpublished_commit,asterinas"
if run_published_inputs > "$scratch/published-missing.log" 2>&1; then
    printf 'published inputs accepted a kernel commit that the repository lacks\n' >&2
    exit 1
fi
rg -q "is not published" "$scratch/published-missing.log"

write_published_lock "$published_kernel_commit" "$published_xsh_commit"
if run_published_inputs > "$scratch/published-gitlink.log" 2>&1; then
    printf 'published inputs accepted a gitlink that differs from the lock\n' >&2
    exit 1
fi
rg -q "gitlink" "$scratch/published-gitlink.log"

git -C "$published_root" update-index --cacheinfo "160000,$published_kernel_commit,asterinas"
write_published_lock "$published_kernel_commit" "0000000000000000000000000000000000000000"
if run_published_inputs > "$scratch/published-xsh.log" 2>&1; then
    printf 'published inputs accepted an XSH commit that the repository lacks\n' >&2
    exit 1
fi
rg -q "xsh commit" "$scratch/published-xsh.log"

vm_test_root="$scratch/vm-fixture"
fake_firecracker="$vm_test_root/firecracker"
mkdir -p "$vm_test_root"
cat > "$fake_firecracker" <<'FIRECRACKER'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FAKE_FIRECRACKER_PID_FILE"
case "$FAKE_FIRECRACKER_MODE" in
    base|success|stalls|fails-after|late-failure|late-panic)
        printf '%s\n' \
            LAPUTA_ASTERINAS_EXT2_MOUNT_OK \
            LAPUTA_ASTERINAS_SWITCH_ROOT_START \
            LAPUTA_ASTERINAS_COLDPLUG_OK \
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
        case "$FAKE_FIRECRACKER_MODE" in
            stalls) exec /bin/sleep 30 ;;
            fails-after) exit 3 ;;
            late-failure) sleep 1; printf '%s\n' 'LAPUTA_ASTERINAS_TEST_FAILED late' ;;
            late-panic) sleep 1; printf '%s\n' 'Kernel panic: late' ;;
        esac
        exit 0
        ;;
    full-success)
        printf '%s\n' \
            'LAPUTA_ASTERINAS_XSH_TEST_START all' \
            LAPUTA_ASTERINAS_XSH_TEST_OK \
            LAPUTA_ASTERINAS_TEST_OK
        exit 0
        ;;
    exact-success)
        printf '%s\n' \
            'LAPUTA_ASTERINAS_XSH_TEST_START core/tests/test-core.xsh::core_suite_fixture' \
            LAPUTA_ASTERINAS_XSH_TEST_OK \
            LAPUTA_ASTERINAS_TEST_OK
        exit 0
        ;;
    batch-success)
        printf '%s\n' \
            'LAPUTA_ASTERINAS_XSH_TEST_START core/tests/test-core.xsh' \
            'LAPUTA_ASTERINAS_XSH_TEST_START tests/xsh/stdlib/fs.xsh' \
            LAPUTA_ASTERINAS_XSH_TEST_OK \
            LAPUTA_ASTERINAS_TEST_OK
        exit 0
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
assert_vm_case full-success all 2 0
assert_vm_case exact-success core/tests/test-core.xsh::core_suite_fixture 2 0
assert_vm_case batch-success 'core/tests/test-core.xsh tests/xsh/stdlib/fs.xsh' 2 0
assert_vm_case batch-success 'core/tests/test-core.xsh tests/xsh/stdlib/numeric.xsh' 2 1
assert_vm_case base tests/xsh/stdlib/numeric.xsh 2 1
assert_vm_case base all 2 1
assert_vm_case failed '' 2 1
assert_vm_case panic '' 2 1
assert_vm_case early '' 2 1
LAPUTA_POWEROFF_POLLS=3 assert_vm_case stalls '' 2 1
grep -Fq 'did not power off' "$vm_test_root/stalls-run.log"
assert_vm_case fails-after '' 2 1
grep -Fq 'exited with status 3 after the guest completion marker' "$vm_test_root/fails-after-run.log"
assert_vm_case late-failure '' 2 1
assert_vm_case late-panic '' 2 1
assert_vm_case timeout '' 3 1
FAKE_FIRECRACKER_MODE=timeout \
FAKE_FIRECRACKER_PID_FILE="$vm_test_root/cancel.pid" \
    bash "$repo_root/infra/asterinas/run-test-vm.sh" \
        "$fake_firecracker" "$vm_test_root/config.json" "$vm_test_root/cancel-console.log" \
        "$vm_test_root/cancel-firecracker.log" '' 1500 > "$vm_test_root/cancel-run.log" 2>&1 &
runner_pid=$!
for _ in {1..100}; do
    [[ -s "$vm_test_root/cancel.pid" ]] && break
    sleep 0.05
done
[[ -s "$vm_test_root/cancel.pid" ]] || { kill "$runner_pid" 2>/dev/null || true; wait "$runner_pid" || true; exit 1; }
guest_pid="$(cat "$vm_test_root/cancel.pid")"
kill -TERM "$runner_pid"
status=0
wait "$runner_pid" || status=$?
[[ "$status" == 143 ]] || { printf 'cancelled VM runner returned %s\n' "$status" >&2; exit 1; }
if kill -0 "$guest_pid" 2>/dev/null; then
    printf 'cancelled VM runner left its Firecracker running\n' >&2
    exit 1
fi
cat > "$vm_test_root/qemu-cancel" <<'QEMU'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$QEMU_CANCEL_PID"
exec sleep 30
QEMU
chmod 755 "$vm_test_root/qemu-cancel"
QEMU_SYSTEM_X86_64="$vm_test_root/qemu-cancel" QEMU_CANCEL_PID="$vm_test_root/qemu-cancel.pid" \
XSH_MODULE_PATH="$repo_root" xsh "$repo_root/infra/asterinas/run-linux.xsh" -- \
    "$vm_test_root/kernel" "$vm_test_root/initramfs" "$vm_test_root/root" \
    "$vm_test_root/qemu-cancel-console" "$vm_test_root/qemu-cancel-log" '' 60 1024 \
    > "$vm_test_root/qemu-cancel-run.log" 2>&1 &
runner_pid=$!
for _ in {1..100}; do
    [[ -s "$vm_test_root/qemu-cancel.pid" ]] && break
    sleep 0.05
done
[[ -s "$vm_test_root/qemu-cancel.pid" ]] || { kill "$runner_pid" 2>/dev/null || true; wait "$runner_pid" || true; exit 1; }
guest_pid="$(cat "$vm_test_root/qemu-cancel.pid")"
kill -TERM "$runner_pid"
wait "$runner_pid" || true
if kill -0 "$guest_pid" 2>/dev/null; then
    kill -TERM "$guest_pid" 2>/dev/null || true
    printf 'cancelled Linux runner left its QEMU child running\n' >&2
    exit 1
fi
if bash "$repo_root/infra/asterinas/run-test-vm.sh" \
    "$vm_test_root/missing-firecracker" "$vm_test_root/config.json" \
    "$vm_test_root/missing-console.log" "$vm_test_root/missing-firecracker.log" '' 2 \
    > "$vm_test_root/missing-firecracker-run.log" 2>&1; then
    printf 'VM runner unexpectedly accepted a missing Firecracker executable\n' >&2
    exit 1
fi
grep -Fq 'Firecracker is not executable' "$vm_test_root/missing-firecracker-run.log"
if bash "$repo_root/infra/asterinas/qualify.sh" baseline --backend both --case unknown > "$scratch/unknown-case.log" 2>&1; then
    printf 'qualification unexpectedly accepted an unknown case\n' >&2
    exit 1
fi
rg -q 'unknown baseline case' "$scratch/unknown-case.log"
if bash "$repo_root/infra/asterinas/qualify.sh" baseline --backend unknown > "$scratch/unknown-backend.log" 2>&1; then
    printf 'qualification unexpectedly accepted an unknown backend\n' >&2
    exit 1
fi
rg -q 'select --backend' "$scratch/unknown-backend.log"
if bash "$repo_root/infra/asterinas/qualify.sh" published-inputs --backend both > "$scratch/published-backend.log" 2>&1; then
    printf 'qualification accepted published-inputs for a backend it does not use\n' >&2
    exit 1
fi
rg -q 'published-inputs takes --backend asterinas' "$scratch/published-backend.log"
account_root="$scratch/account"
mkdir -p "$account_root"
printf '%s\n' \
    '["core/tests/a.xsh::t_improved","core/tests/a.xsh::t_debt","core/tests/a.xsh::t_stable","core/tests/b.xsh::t_in_flight","core/tests/b.xsh::t_late"]' \
    > "$account_root/discovered.json"
write_account_run() {
    local name="$1" improved="$2" stable="$3"
    mkdir -p "$account_root/$name"
    : > "$account_root/$name/interrupted.txt"
    printf '%s\n' \
        'LAPUTA_ASTERINAS_XSH_TEST_START core/tests/a.xsh' \
        "core/tests/a.xsh::t_improved ... $improved 10ms" \
        'core/tests/a.xsh::t_debt ... FAILED 10ms' \
        "core/tests/a.xsh::t_stable ... $stable 10ms" \
        > "$account_root/$name/1.console.log"
}
write_account_run baseline FAILED ok
write_account_run improved ok ok
write_account_run regressed FAILED FAILED
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/baseline" > /dev/null
[[ "$(jaq -c '[.passed, .failed, (.unexecuted | length)]' "$account_root/baseline/accounting.json")" == '[["core/tests/a.xsh::t_stable"],["core/tests/a.xsh::t_debt","core/tests/a.xsh::t_improved"],2]' ]]
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/improved" \
    --baseline "$account_root/baseline/accounting.json" > /dev/null
[[ "$(jaq -c '.failed' "$account_root/improved/accounting.json")" == '["core/tests/a.xsh::t_debt"]' ]]
if bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/regressed" \
    --baseline "$account_root/improved/accounting.json" > "$account_root/regressed.log" 2>&1; then
    printf 'accounting accepted a regressed case\n' >&2
    exit 1
fi
rg -q 'core/tests/a.xsh::t_improved' "$account_root/regressed.log"
mkdir -p "$account_root/empty"
: > "$account_root/empty/interrupted.txt"
: > "$account_root/empty/1.console.log"
if bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/empty" > /dev/null 2>&1; then
    printf 'accounting accepted a log without results\n' >&2
    exit 1
fi
mkdir -p "$account_root/unknown"
: > "$account_root/unknown/interrupted.txt"
printf 'core/tests/z.xsh::t_other ... ok 1ms\n' > "$account_root/unknown/1.console.log"
if bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/unknown" > /dev/null 2>&1; then
    printf 'accounting accepted a result for an undiscovered case\n' >&2
    exit 1
fi
mkdir -p "$account_root/interrupted"
printf 'core/tests/b.xsh\n' > "$account_root/interrupted/interrupted.txt"
printf '%s\n' 'core/tests/a.xsh::t_stable ... ok 1ms' 'core/tests/b.xsh::t_in_flight ... FAILED 1ms' > "$account_root/interrupted/1.console.log"
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/interrupted" > /dev/null
[[ "$(jaq -c '[.failed, (.unexecuted | length)]' "$account_root/interrupted/accounting.json")" == '[[],4]' ]]
printf 'core/tests/a.xsh\n' > "$scratch/native-modules.txt"
if bash "$repo_root/infra/asterinas/native-batches.sh" unknown "$scratch/native-modules.txt" 5 60 "$scratch/native-result" > /dev/null 2>&1; then
    printf 'native batches accepted an unknown backend\n' >&2
    exit 1
fi
: > "$scratch/native-empty.txt"
if bash "$repo_root/infra/asterinas/native-batches.sh" asterinas "$scratch/native-empty.txt" 5 60 "$scratch/native-result" > /dev/null 2>&1; then
    printf 'native batches accepted an empty module list\n' >&2
    exit 1
fi
if bash "$repo_root/infra/asterinas/run-witness.sh" unknown "$repo_root/infra/asterinas/inputs.lock" "$scratch/witness" > /dev/null 2>&1; then
    printf 'witness runner accepted an unknown backend\n' >&2
    exit 1
fi
if bash "$repo_root/infra/asterinas/run-witness.sh" asterinas "$repo_root/infra/asterinas/run-witness.sh" "$scratch/witness" > /dev/null 2>&1; then
    printf 'witness runner accepted a source outside the regression tree\n' >&2
    exit 1
fi
printf 'Asterinas host checks passed.\n'
