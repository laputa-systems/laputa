#!/usr/bin/env bash
set -euo pipefail

cargo_home="${CARGO_HOME:?CARGO_HOME must point at the fetched Cargo cache}"
lock_files=("$@")
[[ ${#lock_files[@]} -gt 0 ]] || {
    printf 'usage: CARGO_HOME=... %s Cargo.lock...\n' "$0" >&2
    exit 2
}

while IFS= read -r source; do
    [[ "$source" == *'?tag='* ]] || continue
    repository="${source%%\?tag=*}"
    tag_and_revision="${source#*\?tag=}"
    tag="${tag_and_revision%%#*}"
    revision="${tag_and_revision##*#}"
    repository_name="${repository##*/}"
    repository_name="${repository_name%.git}"
    [[ "$tag" != "$tag_and_revision" && "$revision" =~ ^[0-9a-f]{40}$ ]] || {
        printf 'invalid locked Cargo git tag source: %s\n' "$source" >&2
        exit 1
    }
    git check-ref-format "refs/tags/$tag" >/dev/null || {
        printf 'invalid Cargo git tag in lockfile: %s\n' "$tag" >&2
        exit 1
    }

    found_database=false
    for database in "$cargo_home"/git/db/"$repository_name"-*; do
        [[ -d "$database" ]] || continue
        if git --git-dir="$database" cat-file -e "$revision^{commit}" 2>/dev/null; then
            if [[ "$tag" == */* ]]; then
                mkdir -p "$database/refs/remotes/origin/tags/${tag%/*}"
            else
                mkdir -p "$database/refs/remotes/origin/tags"
            fi
            git --git-dir="$database" update-ref "refs/remotes/origin/tags/$tag" "$revision"
            found_database=true
        fi
    done
    [[ "$found_database" == true ]] || {
        printf 'Cargo did not cache locked repository commit %s for %s\n' "$revision" "$repository" >&2
        exit 1
    }
done < <(sed -n 's/^source = "git+\([^"]*\)"/\1/p' "${lock_files[@]}" | sort -u)
