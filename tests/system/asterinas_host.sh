#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/inputs.lock"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/laputa-asterinas-host.XXXXXX")"
trap 'chmod -R u+w -- "$scratch"; rm -rf -- "$scratch"' EXIT

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

setup_root="$scratch/setup-fixture"
setup_source="$setup_root/asterinas"
setup_toolchain="$setup_root/toolchain"
setup_fake_bin="$scratch/setup-bin"
setup_marker="$scratch/setup-version-ran"
setup_image_id=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
setup_image_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
setup_firecracker_version=v1.17.0
setup_archive_name="firecracker-$setup_firecracker_version-x86_64.tgz"
setup_archive="$scratch/$setup_archive_name"
setup_checksum="$scratch/$setup_archive_name.sha256.txt"
mkdir -p "$setup_root/infra/asterinas" "$setup_source/osdk" \
    "$setup_toolchain/lib/rustlib/src/rust/library" "$setup_fake_bin"
cp "$repo_root/infra/asterinas/setup.sh" "$setup_root/infra/asterinas/setup.sh"
printf '%s\n' '[toolchain]' "channel = \"nightly-2026-09-01\"" > "$setup_source/rust-toolchain.toml"
printf '%s\n' '0.18.1-test' > "$setup_source/DOCKER_IMAGE_VERSION"
printf '%s\n' 'version = 4' > "$setup_source/Cargo.lock"
printf '%s\n' 'version = 4' > "$setup_source/osdk/Cargo.lock"
printf '%s\n' 'version = 4' > "$setup_toolchain/lib/rustlib/src/rust/library/Cargo.lock"
git -C "$setup_source" init -q
git -C "$setup_source" config user.email asterinas-test@example.invalid
git -C "$setup_source" config user.name Asterinas
git -C "$setup_source" remote add origin https://github.com/joshuarli/asterinas.git
git -C "$setup_source" add --all
git -C "$setup_source" commit -qm 'test(asterinas): pin setup fixture'
setup_source_commit="$(git -C "$setup_source" rev-parse HEAD)"
git -C "$setup_root" init -q
git -C "$setup_root" update-index --add --cacheinfo "160000,$setup_source_commit,asterinas"
cat > "$scratch/fake-firecracker" <<'FIRECRACKER'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
    printf 'ran\n' > "$ASTERINAS_TEST_FIRECRACKER_MARKER"
    printf 'Firecracker v1.17.0\n'
fi
FIRECRACKER
chmod 755 "$scratch/fake-firecracker"
mkdir -p "$scratch/firecracker-archive"
cp "$scratch/fake-firecracker" \
    "$scratch/firecracker-archive/firecracker-$setup_firecracker_version-x86_64"
tar -czf "$setup_archive" -C "$scratch/firecracker-archive" \
    "firecracker-$setup_firecracker_version-x86_64"
setup_archive_hash="$(sha256_file "$setup_archive")"
printf '%s *%s\n' "$setup_archive_hash" "$setup_archive_name" > "$setup_checksum"
setup_binary_hash="$(sha256_file "$scratch/fake-firecracker")"
setup_hash_tool=sha256sum
if command -v sha256sum >/dev/null 2>&1; then
    setup_hash_tool_path="$(command -v sha256sum)"
else
    setup_hash_tool=shasum
    setup_hash_tool_path="$(command -v shasum)"
fi
cat > "$setup_fake_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == image && "${2:-}" == inspect ]]; then
    case "$*" in
        *RepoDigests*) printf 'asterinas/dev@%s\n' "$ASTERINAS_TEST_IMAGE_DIGEST" ;;
        *'.Id'*) printf '%s\n' "$ASTERINAS_TEST_IMAGE_ID" ;;
        *) exit 2 ;;
    esac
    exit 0
fi
if [[ "${1:-}" == info && $# == 1 ]]; then
    exit 0
fi
[[ "${1:-}" == run ]] || exit 2
shift
entrypoint=''
while (($#)); do
    if [[ "$1" == --entrypoint ]]; then
        entrypoint="$2"
        shift 2
    elif [[ "$1" == "$ASTERINAS_TEST_IMAGE_ID" ]]; then
        shift
        break
    else
        shift
    fi
done
[[ -n "$entrypoint" && $# -gt 0 ]] || exit 2
case "$entrypoint" in
    /usr/bin/tar)
        cat >/dev/null
        printf 'asterinas setup fixture archive\n'
        ;;
    /usr/bin/env)
        case "${1:-}" in
            rustc)
                if [[ "${2:-}" == --print && "${3:-}" == sysroot ]]; then
                    printf '%s\n' "$ASTERINAS_TEST_SYSROOT"
                elif [[ "${2:-}" == --version ]]; then
                    printf '%s\n' 'rustc fake version'
                else
                    exit 2
                fi
                ;;
            cargo)
                if [[ "${2:-}" == --version ]]; then
                    printf '%s\n' 'cargo fake version'
                elif [[ "${2:-}" != fetch ]]; then
                    exit 2
                fi
                ;;
            gcc)
                [[ "${2:-}" == --version ]] || exit 2
                printf '%s\n' 'gcc fake version'
                ;;
            cpio|gzip|jq)
                [[ "${2:-}" == --version ]] || exit 2
                printf '%s\n' 'fake tool version'
                ;;
            bash)
                [[ "${2:-}" == infra/asterinas/seed-cargo-git-tags.sh ]] || exit 2
                ;;
            *) exit 2 ;;
        esac
        ;;
    /usr/bin/sha256sum)
        hash_args=()
        [[ "$ASTERINAS_TEST_HASH_TOOL" == shasum ]] && hash_args+=(-a 256)
        exec "$ASTERINAS_TEST_HASH_TOOL_PATH" "${hash_args[@]}" "$@"
        ;;
    /usr/bin/test)
        [[ "${1:-}" == -d && "${2:-}" == /root/linux_vdso ]] || exit 2
        exit 0
        ;;
    *) exit 2 ;;
esac
DOCKER
cat > "$setup_fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
output=''
url=''
while (($#)); do
    case "$1" in
        --output) output="$2"; shift ;;
        --retry) shift ;;
        --*) ;;
        *) url="$1" ;;
    esac
    shift
done
[[ -n "$output" && -n "$url" ]]
if [[ "$url" == *.sha256.txt ]]; then
    cp "$ASTERINAS_TEST_FIRECRACKER_CHECKSUM" "$output"
elif [[ "$url" == */"$ASTERINAS_TEST_FIRECRACKER_ARCHIVE_NAME" ]]; then
    cp "$ASTERINAS_TEST_FIRECRACKER_ARCHIVE" "$output"
else
    exit 2
fi
CURL
cat > "$setup_fake_bin/uname" <<'UNAME'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf '%s\n' Linux ;;
    -m) printf '%s\n' x86_64 ;;
    *) exit 2 ;;
esac
UNAME
cat > "$setup_fake_bin/readelf" <<'READELF'
#!/usr/bin/env bash
exit 2
READELF
cat > "$setup_fake_bin/sha256sum" <<'SHA256SUM'
#!/usr/bin/env bash
set -euo pipefail
hash_args=()
[[ "$ASTERINAS_TEST_HASH_TOOL" == shasum ]] && hash_args+=(-a 256)
exec "$ASTERINAS_TEST_HASH_TOOL_PATH" "${hash_args[@]}" "$@"
SHA256SUM
chmod 755 "$setup_fake_bin/docker" "$setup_fake_bin/curl" \
    "$setup_fake_bin/uname" "$setup_fake_bin/readelf" "$setup_fake_bin/sha256sum"
setup_environment=(
    "PATH=$setup_fake_bin:$PATH"
    "ASTERINAS_TEST_SYSROOT=$setup_toolchain"
    "ASTERINAS_TEST_IMAGE_ID=$setup_image_id"
    "ASTERINAS_TEST_IMAGE_DIGEST=$setup_image_digest"
    "ASTERINAS_TEST_FIRECRACKER_ARCHIVE=$setup_archive"
    "ASTERINAS_TEST_FIRECRACKER_ARCHIVE_NAME=$setup_archive_name"
    "ASTERINAS_TEST_FIRECRACKER_CHECKSUM=$setup_checksum"
    "ASTERINAS_TEST_FIRECRACKER_MARKER=$setup_marker"
    "ASTERINAS_TEST_HASH_TOOL=$setup_hash_tool"
    "ASTERINAS_TEST_HASH_TOOL_PATH=$setup_hash_tool_path"
)
write_setup_lock() {
    cat > "$setup_root/infra/asterinas/inputs.lock" <<LOCK
ASTERINAS_REPOSITORY=https://github.com/joshuarli/asterinas.git
ASTERINAS_COMMIT=$setup_source_commit
ASTERINAS_DEV_IMAGE_VERSION=0.18.1-test
ASTERINAS_DEV_IMAGE_DIGEST=$setup_image_digest
FIRECRACKER_VERSION=$setup_firecracker_version
FIRECRACKER_BINARY_SHA256=$1
XSH_REPOSITORY=https://github.com/laputa-systems/xsh.git
XSH_COMMIT=0000000000000000000000000000000000000000
LOCK
}
write_setup_lock 0000000000000000000000000000000000000000000000000000000000000000
if env "${setup_environment[@]}" \
    bash "$setup_root/infra/asterinas/setup.sh" fetch > "$scratch/setup-wrong-pin.log" 2>&1; then
    printf 'Asterinas setup unexpectedly accepted a Firecracker binary with the wrong pin\n' >&2
    exit 1
fi
grep -Fq 'Firecracker binary checksum mismatch' "$scratch/setup-wrong-pin.log" || {
    cat "$scratch/setup-wrong-pin.log" >&2
    printf 'Asterinas setup did not reach the Firecracker binary pin check\n' >&2
    exit 1
}
[[ ! -e "$setup_marker" ]] || {
    printf 'Asterinas setup executed a Firecracker binary before validating its pin\n' >&2
    exit 1
}
[[ ! -e "$setup_root/.out/asterinas-firecracker/bin/firecracker" ]]
[[ ! -e "$setup_root/.out/asterinas-firecracker/firecracker.version" ]]
[[ ! -e "$setup_root/.out/asterinas-firecracker/firecracker.sha256" ]]
write_setup_lock "$setup_binary_hash"
if ! env "${setup_environment[@]}" \
    bash "$setup_root/infra/asterinas/setup.sh" fetch > "$scratch/setup-matching-pin.log" 2>&1; then
    cat "$scratch/setup-matching-pin.log" >&2
    printf 'Asterinas setup rejected a matching Firecracker binary pin\n' >&2
    exit 1
fi
[[ -s "$setup_marker" ]]
[[ -x "$setup_root/.out/asterinas-firecracker/bin/firecracker" ]]
[[ "$(sha256_file "$setup_root/.out/asterinas-firecracker/bin/firecracker")" == "$setup_binary_hash" ]]
[[ "$(cat "$setup_root/.out/asterinas-firecracker/firecracker.version")" == "$setup_firecracker_version" ]]
[[ "$(cat "$setup_root/.out/asterinas-firecracker/firecracker.sha256")" == "$setup_binary_hash" ]]

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
[[ "$(cat "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-test.selection")" == tests/xsh/stdlib/fs.xsh ]]
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
[[ "$(cat "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-test.selection")" == core/tests/test-core.xsh::core_suite_fixture ]]

ln -s "$scratch/outside-test.xsh" "$xsh_root/tests/xsh/stdlib/escape.xsh"
printf 'outside\n' > "$scratch/outside-test.xsh"
before_invalid_stage="$(sha256_file "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-test.selection")"
assert_xsh_test_rejected() {
    local module="$1"
    local log="$scratch/xsh-stage-rejected.log"
    if bash "$repo_root/infra/asterinas/stage-xsh-test.sh" \
        "$xsh_root" "$module" "$xsh_output" > "$log" 2>&1; then
        printf 'XSH test staging unexpectedly accepted %s\n' "$module" >&2
        exit 1
    fi
    [[ -s "$log" ]]
    [[ "$(sha256_file "$xsh_output/xsh-test-overlay/usr/lib/asterinas/xsh-test.selection")" == "$before_invalid_stage" ]]
}
assert_xsh_test_rejected ../tests/xsh/stdlib/fs.xsh
assert_xsh_test_rejected core/tests/../../tests/xsh/stdlib/fs.xsh
assert_xsh_test_rejected tests/xsh/stdlib/escape.xsh
assert_xsh_test_rejected tests/xsh/stdlib/missing.xsh

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

prepare_root="$scratch/prepare-xsh-fixture"
prepare_source="$scratch/prepare-xsh-source"
mkdir -p "$prepare_root/infra/asterinas" \
    "$prepare_source/tests/xsh" "$prepare_source/docs" \
    "$prepare_source/core/tests/fixtures/util-linux/paths/bind/target"
cp "$repo_root/infra/asterinas/prepare-xsh.sh" "$prepare_root/infra/asterinas/prepare-xsh.sh"
printf 'target\n' > "$prepare_source/.gitignore"
printf 'test xsh_fixture { assert true }\n' > "$prepare_source/tests/xsh/test.xsh"
printf 'XSH specification fixture\n' > "$prepare_source/docs/SPEC.md"
printf 'module_path = .\ntest_roots = core/tests\n  dev/tests\n  tests\n  showcase/tests\n' > "$prepare_source/xsht-config.ini"
printf 'keep\n' > "$prepare_source/core/tests/fixtures/util-linux/paths/bind/target/sentinel"
git -C "$prepare_source" init -q
git -C "$prepare_source" config user.email asterinas-test@example.invalid
git -C "$prepare_source" config user.name Asterinas
git -C "$prepare_source" add --force --all
git -C "$prepare_source" commit -qm 'pinned fixture source'
prepare_commit="$(git -C "$prepare_source" rev-parse HEAD)"
cat > "$prepare_root/infra/asterinas/inputs.lock" <<LOCK
XSH_REPOSITORY=https://github.com/laputa-systems/xsh.git
XSH_COMMIT=$prepare_commit
LOCK
mkdir -p "$prepare_root/.cache/asterinas"
git init --bare -q "$prepare_root/.cache/asterinas/xsh.git"
git --git-dir="$prepare_root/.cache/asterinas/xsh.git" \
    fetch --quiet --no-tags --depth=1 "$prepare_source" "$prepare_commit"
readarray -t prepared_xsh < <(bash "$prepare_root/infra/asterinas/prepare-xsh.sh")
[[ ${#prepared_xsh[@]} == 2 ]]
prepared_source="${prepared_xsh[0]}"
prepared_tree="$(git -C "$prepared_source" rev-parse 'HEAD^{tree}')"
source_tree="$(git -C "$prepare_source" rev-parse 'HEAD^{tree}')"
[[ "$prepared_tree" == "$source_tree" ]] || {
    printf 'XSH snapshot dropped tracked archive inputs\n' >&2
    exit 1
}
readarray -t prepared_overlay < <(
    bash "$repo_root/infra/asterinas/stage-xsh-test.sh" "$prepared_source" all "$prepare_root/.out"
)
[[ ${#prepared_overlay[@]} == 3 ]]
[[ "$(cat "${prepared_overlay[0]}/usr/lib/asterinas/xsh-source/core/tests/fixtures/util-linux/paths/bind/target/sentinel")" == keep ]]

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
    full-success)
        printf '%s\n' \
            'LAPUTA_ASTERINAS_XSH_TEST_START all' \
            LAPUTA_ASTERINAS_XSH_TEST_OK \
            LAPUTA_ASTERINAS_TEST_OK
        exec /bin/sleep 30
        ;;
    exact-success)
        printf '%s\n' \
            'LAPUTA_ASTERINAS_XSH_TEST_START core/tests/test-core.xsh::core_suite_fixture' \
            LAPUTA_ASTERINAS_XSH_TEST_OK \
            LAPUTA_ASTERINAS_TEST_OK
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
assert_vm_case full-success all 2 0
assert_vm_case exact-success core/tests/test-core.xsh::core_suite_fixture 2 0
assert_vm_case base tests/xsh/stdlib/numeric.xsh 2 1
assert_vm_case base all 2 1
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
