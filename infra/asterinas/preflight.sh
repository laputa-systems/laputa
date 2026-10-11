#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/inputs.lock"

fail() {
    printf 'asterinas-preflight: %s\n' "$*" >&2
    exit 1
}

for tool in awk cat cc docker find git make readelf sha256sum sort uname; do
    command -v "$tool" >/dev/null 2>&1 || fail "required host command is missing: $tool"
done

[[ "$(uname -s)" == Linux ]] || fail 'Firecracker requires a Linux host'
[[ "$(uname -m)" == x86_64 ]] || fail "Firecracker requires x86_64, found $(uname -m)"
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || fail '/dev/kvm must be readable and writable by this user'
docker info >/dev/null 2>&1 || fail 'Docker is unavailable to this user'

[[ "$ASTERINAS_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'invalid Asterinas commit pin'
[[ "$XSH_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'invalid XSH commit pin'
[[ "$XSH_REPOSITORY" == https://github.com/laputa-systems/xsh.git ]] || fail 'invalid XSH repository pin'
[[ "$ASTERINAS_DEV_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'invalid Asterinas dev image digest'
[[ "$FIRECRACKER_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid Firecracker binary digest'

dev_image="asterinas/dev:$ASTERINAS_DEV_IMAGE_VERSION"
if docker image inspect "$dev_image" >/dev/null 2>&1; then
    dev_digest="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$dev_image")"
    [[ "$dev_digest" == "asterinas/dev@$ASTERINAS_DEV_IMAGE_DIGEST" ]] || \
        fail "cached Asterinas image has the wrong digest: $dev_digest"
else
    printf 'Asterinas dev image is not fetched yet; run make asterinas-fetch.\n'
fi

firecracker_bin="$repo_root/.out/asterinas-firecracker/bin/firecracker"
if [[ -x "$firecracker_bin" ]]; then
    firecracker_hash="$(sha256sum "$firecracker_bin" | awk '{print $1}')"
    [[ "$firecracker_hash" == "$FIRECRACKER_BINARY_SHA256" ]] || \
        fail "installed Firecracker binary does not match $FIRECRACKER_VERSION"
else
    printf 'Firecracker is not fetched yet; run make asterinas-fetch.\n'
fi

printf 'Preflight passed: Linux x86_64, KVM, Docker, and pinned input declarations.\n'
