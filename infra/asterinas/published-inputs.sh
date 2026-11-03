#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/inputs.lock"

fail() {
    printf 'published-inputs: %s\n' "$*" >&2
    exit 1
}

export TMPDIR="$repo_root/.work/tmp"
mkdir -p "$TMPDIR"
work="$(mktemp -d "$TMPDIR/published-inputs.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

fetch_pin() {
    local name="$1" repository="$2" commit="$3" cache="$work/$1.git" fetched
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "$name pin is not a full commit id: $commit"
    git init --bare --quiet "$cache"
    git --git-dir="$cache" fetch --quiet --no-tags --depth=1 "$repository" "$commit" || \
        fail "$name commit $commit is not published at $repository"
    fetched="$(git --git-dir="$cache" rev-parse FETCH_HEAD^{commit})"
    [[ "$fetched" == "$commit" ]] || fail "$name fetch returned $fetched, the lock pins $commit"
    git --git-dir="$cache" cat-file -e "$commit^{commit}" || fail "$name commit $commit is missing after the fetch"
}

gitlink="$(git -C "$repo_root" ls-files --stage -- asterinas | awk '$1 == "160000" && $4 == "asterinas" { print $2 }')"
[[ "$gitlink" == "$ASTERINAS_COMMIT" ]] || fail "the Asterinas gitlink $gitlink differs from the lock $ASTERINAS_COMMIT"

fetch_pin asterinas "$ASTERINAS_REPOSITORY" "$ASTERINAS_COMMIT"
fetch_pin xsh "$XSH_REPOSITORY" "$XSH_COMMIT"

kernel_image_version="$(git --git-dir="$work/asterinas.git" show "$ASTERINAS_COMMIT:DOCKER_IMAGE_VERSION")"
[[ "$kernel_image_version" == "$ASTERINAS_DEV_IMAGE_VERSION" ]] || \
    fail "the published kernel expects dev image $kernel_image_version, the lock selects $ASTERINAS_DEV_IMAGE_VERSION"
git --git-dir="$work/xsh.git" cat-file -e "$XSH_COMMIT:Dockerfile.test" || fail 'the published XSH pin has no Dockerfile.test'

printf 'published-inputs: kernel %s and XSH %s match the lock and the gitlink\n' "$ASTERINAS_COMMIT" "$XSH_COMMIT"
