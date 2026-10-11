#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

fail() {
    printf 'asterinas-test: %s\n' "$*" >&2
    exit 2
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        fail 'sha256sum or shasum is required to identify the staged module'
    fi
}

[[ $# == 3 ]] || fail 'usage: stage-xsh-test.sh XSH_SNAPSHOT TEST_MODULE OUTPUT_DIR'
[[ -d "$1" ]] || fail "XSH snapshot does not exist: $1"
snapshot="$(realpath "$1")" || fail "could not resolve XSH snapshot: $1"
test_module="$2"
output_dir="$3"

[[ "$test_module" == tests/xsh/*.xsh && "$test_module" != *$'\n'* ]] || \
    fail 'XSH_TEST must name a module below tests/xsh and end in .xsh'
IFS=/ read -r -a module_components <<< "$test_module"
for component in "${module_components[@]}"; do
    [[ "$component" != . && "$component" != .. ]] || fail 'XSH_TEST must use a normalized relative path'
done

test_path="$(realpath "$snapshot/$test_module")" || fail "XSH test module does not exist in the pinned checkout: $test_module"
[[ "$test_path" == "$snapshot/$test_module" && -f "$test_path" ]] || \
    fail 'XSH_TEST must resolve to a regular file inside the pinned tests/xsh tree'
[[ -d "$snapshot/tests/xsh" && -f "$snapshot/docs/SPEC.md" ]] || \
    fail "XSH snapshot is missing tests or docs: $snapshot"

test_sha256="$(sha256_file "$test_path")"
stage="$output_dir/.xsh-test-overlay.tmp.$$"
overlay="$output_dir/xsh-test-overlay"
rm -rf -- "$stage"
mkdir -p "$stage"
trap 'if [[ -d "$stage" ]]; then chmod -R u+w "$stage"; rm -rf -- "$stage"; fi' EXIT
cp -a "$repo_root/guest/asterinas/viability/overlay/." "$stage/"
cat > "$stage/overlay.json" <<'OVERLAY'
{
  "format": "laputa-generation-overlay-1",
  "profile": "asterinas-viability-xsh-test",
  "replacements": [
    "etc/inittab"
  ]
}
OVERLAY

source_root="$stage/usr/lib/asterinas/xsh-source"
mkdir -p "$source_root/tests" "$source_root/docs"
cp -a "$snapshot/tests/." "$source_root/tests/"
cp "$snapshot/docs/SPEC.md" "$source_root/docs/SPEC.md"
cat > "$source_root/xsht-config.ini" <<'CONFIG'
module_path = .
test_roots = tests
CONFIG
printf '%s\n' "$test_module" > "$stage/usr/lib/asterinas/xsh-test.path"

mkdir -p "$output_dir"
if [[ -e "$overlay" ]]; then
    chmod -R u+w "$overlay"
    rm -rf -- "$overlay"
fi
mv "$stage" "$overlay"
trap - EXIT
printf '%s\n%s\n%s\n' "$overlay" "$test_module" "$test_sha256"
