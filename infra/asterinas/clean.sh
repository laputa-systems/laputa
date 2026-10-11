#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/inputs.lock"

make -C "$repo_root" distclean

for image in xsh-test "asterinas/dev:$ASTERINAS_DEV_IMAGE_VERSION"; do
    if docker image inspect "$image" >/dev/null 2>&1; then
        docker image rm --force "$image"
    fi
done
