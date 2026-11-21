#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS"
FAKE
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH" DOCKER_CALLS="$work/calls"

check() {
    local expected="$1" actual
    actual="$(tail -n 1 "$DOCKER_CALLS")"
    [[ "$actual" == "$expected" ]] || { printf 'cpu-budget: expected %q, got %q\n' "$expected" "$actual" >&2; exit 1; }
}

(
    source "$repo_root/infra/asterinas/cpu-budget.sh"
    unset CPU_SLOT_CPUS
    docker run --rm image true
    check 'run --rm image true'
    CPU_SLOT_CPUS=8,9,10,11 docker run --rm image true
    check 'run --cpuset-cpus=8,9,10,11 --rm image true'
    CPU_SLOT_CPUS=8,9 docker image inspect image
    check 'image inspect image'
)
(
    source "$repo_root/infra/asterinas/run-cancellable.sh"
    CPU_SLOT_CPUS=12 docker run image
    check 'run --cpuset-cpus=12 image'
)
printf 'asterinas cpu budget: ok\n'
