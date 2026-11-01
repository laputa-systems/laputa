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

[[ $# == 3 ]] || fail 'usage: stage-xsh-test.sh XSH_SNAPSHOT TEST_SELECTION OUTPUT_DIR'
[[ -d "$1" ]] || fail "XSH snapshot does not exist: $1"
snapshot="$(realpath "$1")" || fail "could not resolve XSH snapshot: $1"
test_selection="$2"
output_dir="$3"

read -r -a selections <<< "$test_selection"
[[ ${#selections[@]} -ge 1 && "$test_selection" != *$'\n'* ]] || fail 'XSH_TEST must name at least one selection on one line'
if [[ ${#selections[@]} -gt 1 ]]; then
    for selection in "${selections[@]}"; do
        [[ "$selection" != all ]] || fail 'XSH_TEST all cannot be combined with other selections'
    done
fi
test_selection="${selections[*]}"
for selection in "${selections[@]}"; do
    [[ "$selection" == all || \
       ( "${selection%%::*}" == tests/xsh/*.xsh || "${selection%%::*}" == core/tests/*.xsh || \
         "${selection%%::*}" == dev/tests/*.xsh || "${selection%%::*}" == showcase/tests/*.xsh ) ]] || \
        fail 'XSH_TEST must be all or select a module from one of the native test roots'
    if [[ "$selection" != all ]]; then
        test_module="${selection%%::*}"
        if [[ "$selection" == *::* ]]; then
            exact_test_name="${selection#*::}"
            [[ "$exact_test_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$exact_test_name" != *::* ]] || \
                fail 'XSH_TEST exact selection must end with one native test name'
        fi
        IFS=/ read -r -a module_components <<< "$test_module"
        for component in "${module_components[@]}"; do
            [[ "$component" != . && "$component" != .. ]] || fail 'XSH_TEST must use a normalized relative path'
        done

        test_path="$(realpath "$snapshot/$test_module")" || fail "XSH test module does not exist in the pinned checkout: $test_module"
        [[ "$test_path" == "$snapshot/$test_module" && -f "$test_path" ]] || \
            fail 'XSH_TEST must resolve to a regular file inside a native test root'
    fi
done

[[ -d "$snapshot/tests/xsh" && -f "$snapshot/docs/SPEC.md" && -f "$snapshot/xsht-config.ini" ]] || \
    fail "XSH snapshot is missing native tests or project configuration: $snapshot"
command -v tar >/dev/null 2>&1 || fail 'tar is required to stage the pinned XSH source archive'
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
mkdir -p "$source_root"
source_archive="$stage/xsh-source.tar"
git -C "$snapshot" archive --format=tar HEAD > "$source_archive"
test_sha256="$(sha256_file "$source_archive")"
tar -xf "$source_archive" -C "$source_root"
rm -f "$source_archive"
# The repository's environment activation script is unrelated to the test
# corpus and can change the behavior of child shells launched by tests.
rm -f "$source_root/.envrc"

mkdir -p "$output_dir"
printf '%s\n' "${selections[@]}" > "$output_dir/.xsh-test.selection.tmp.$$"
mv -f "$output_dir/.xsh-test.selection.tmp.$$" "$output_dir/xsh-test.selection"
if [[ -e "$overlay" ]]; then
    chmod -R u+w "$overlay"
    rm -rf -- "$overlay"
fi
mv "$stage" "$overlay"
trap - EXIT
printf '%s\n%s\n%s\n' "$overlay" "$test_selection" "$test_sha256"
