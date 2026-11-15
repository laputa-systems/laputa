#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/inputs.lock"

make -C "$repo_root" distclean

images=()
while IFS= read -r image; do
    [[ "$image" =~ ^xsh-test:[0-9a-f]{16}$ ]] && images+=("$image")
done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' xsh-test)
images+=("asterinas/dev:$ASTERINAS_DEV_IMAGE_VERSION")
for image in "${images[@]}"; do
    if docker image inspect "$image" >/dev/null 2>&1; then
        docker image rm --force "$image"
    fi
done
