#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
: "${XSH_ROOT:?set XSH_ROOT to an XSH checkout}"
: "${XSH_BIN_DIR:?set XSH_BIN_DIR to host XSH binaries}"
mkdir -p "$repo_root/.work/tmp"
export TMPDIR="$repo_root/.work/tmp"
work="$(mktemp -d "$TMPDIR/seed-admission.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/laputa/infra/asterinas" "$work/stale/.cargo" "$work/stale/core"
cp "$repo_root/Makefile" "$work/laputa/Makefile"
cp "$repo_root/infra/asterinas/inputs.lock" "$work/laputa/infra/asterinas/inputs.lock"
for path in seed pm packages pm.xsh mirror; do ln -s "$repo_root/$path" "$work/laputa/$path"; done
source "$repo_root/infra/asterinas/inputs.lock"
git -C "$work/stale" init -q
git -C "$work/stale" -c user.name='Seed test' -c user.email=seed@example.invalid commit -q --allow-empty -m fixture
stale="$(git -C "$work/stale" rev-parse HEAD)"
touch "$work/stale/Cargo.lock" "$work/stale/.cargo/config.toml" "$work/stale/Dockerfile.test"
printf '#!/bin/sh\nprintf invoked >> "%s"\nexit 1\n' "$work/docker-called" > "$work/docker"
chmod +x "$work/docker"
if (cd "$work/laputa" && DOCKER="$work/docker" make seed ARCH=x86_64 XSH_ROOT="$work/stale" XSH_BIN_DIR="$XSH_BIN_DIR") > "$work/build.log" 2>&1; then
    printf 'stale checkout was accepted\n' >&2; exit 1
fi
[[ ! -e "$work/docker-called" ]]
rg -q -F "$stale" "$work/build.log"
rg -q -F "$XSH_COMMIT" "$work/build.log"
rg -q -F "update XSH_ROOT to a descendant of $XSH_COMMIT" "$work/build.log"
printf 'seed-admission: stale checkout rejected before Docker or cargo\n'
parent="$(git -C "$XSH_ROOT" rev-parse "$XSH_COMMIT^")"
mkdir -p "$work/laputa/.out/seed/x86_64"
printf '{"xsh_commit":"%s","xsh_dirty":false}\n' "$parent" > "$work/laputa/.out/seed/x86_64/manifest.json"
if (cd "$work/laputa" && make need-xsh ARCH=x86_64 XSH_ROOT="$XSH_ROOT" XSH_BIN_DIR="$XSH_BIN_DIR") > "$work/manifest.log" 2>&1; then
    printf 'stale manifest was accepted\n' >&2; exit 1
fi
rg -q -F "$parent" "$work/manifest.log"
rg -q -F "$XSH_COMMIT" "$work/manifest.log"
rg -F 'run `make seed`' "$work/manifest.log"
printf 'seed-admission: stale manifest rejected by need-xsh\n'
for target in profile-test installer-image publish root; do
    if (cd "$work/laputa" && make "$target" ARCH=x86_64 XSH_ROOT="$XSH_ROOT" XSH_BIN_DIR="$XSH_BIN_DIR") > "$work/target.log" 2>&1; then
        printf '%s accepted a stale manifest\n' "$target" >&2; exit 1
    fi
    rg -q -F "$parent" "$work/target.log"
    rg -q -F "$XSH_COMMIT" "$work/target.log"
    rg -q -F 'run `make seed`' "$work/target.log"
done
printf 'seed-admission: profile-test installer-image publish root reject stale manifests\n'
printf '{"xsh_commit":"%s","xsh_dirty":true}\n' "$(git -C "$XSH_ROOT" rev-parse HEAD)" > "$work/laputa/.out/seed/x86_64/manifest.json"
(cd "$work/laputa" && make need-xsh ARCH=x86_64 XSH_ROOT="$XSH_ROOT" XSH_BIN_DIR="$XSH_BIN_DIR")
printf 'seed-admission: descendant manifest accepted\n'
mkdir -p "$work/laputa/.cache/cargo" "$work/laputa/.out"
printf '%s:%s' "$(sha256sum "$XSH_ROOT/Cargo.lock" | cut -d ' ' -f 1)" "$(sha256sum "$XSH_ROOT/.cargo/config.toml" | cut -d ' ' -f 1)" > "$work/laputa/.cache/cargo/Cargo.lock.sha256"
ln -s "$work/missing-target" "$work/laputa/.out/xsh-target"
cat > "$work/docker" <<'DOCKER'
#!/bin/sh
if [ "$1" = image ]; then exit 0; fi
[ -d "$LAPUTA_TEST_TARGET" ] && [ ! -L "$LAPUTA_TEST_TARGET" ] || exit 2
printf repaired > "$LAPUTA_TEST_MARKER"
exit 1
DOCKER
chmod +x "$work/docker"
if (cd "$work/laputa" && DOCKER="$work/docker" LAPUTA_TEST_TARGET="$work/laputa/.out/xsh-target" LAPUTA_TEST_MARKER="$work/repaired" make seed ARCH=x86_64 XSH_ROOT="$XSH_ROOT" XSH_BIN_DIR="$XSH_BIN_DIR") > "$work/repair.log" 2>&1; then
    printf 'fake cargo unexpectedly succeeded\n' >&2; exit 1
fi
if [[ ! -f "$work/repaired" ]]; then cat "$work/repair.log" >&2; exit 1; fi
[[ "$(cat "$work/repaired")" == repaired ]]
printf 'seed-admission: seed build repaired dangling target before cargo\n'
