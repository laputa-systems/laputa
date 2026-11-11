#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
seed=${1:?usage: closed_build.sh XSH_SEED_DIRECTORY [SEED_IMAGE]}
seed=$(cd -- "$seed" && pwd)
seed_image=${2:-xsh-test}
seed_image=$(docker image inspect --format '{{.Id}}' "$seed_image")
mkdir -p "$repo/.work/tmp"
export TMPDIR="$repo/.work/tmp"
work=$(mktemp -d "$TMPDIR/closed-build.XXXXXXXX")
image="laputa-closed-build-test:$(basename -- "$work")"
seed_tag="laputa-closed-build-seed:$(basename -- "$work")"
container="laputa-$(basename -- "$work")"
build_uid=$(id -u)
build_gid=$(id -g)
if test "$build_uid" = 0; then build_uid=65534; fi
cleanup() {
  result=$?
  trap - EXIT
  if docker container inspect "$container" >/dev/null 2>&1; then docker rm -f "$container" >/dev/null || result=1; fi
  if docker image inspect "$image" >/dev/null 2>&1; then docker image rm "$image" >/dev/null || result=1; fi
  if docker image inspect "$seed_tag" >/dev/null 2>&1; then docker image rm "$seed_tag" >/dev/null || result=1; fi
  rm -rf -- "$work" || result=1
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir -p "$work/context/bin" "$work/context/core" "$work/output-one" "$work/output-two" "$work/ambient"
mkdir -p "$work/context/links/usr/bin"
ln -s -- ../lib/llvm23/bin/clang "$work/context/links/usr/bin/clang"
chmod 0777 "$work/output-one" "$work/output-two"
# A frozen tool snapshot keeps its runners under bin/; the installed seed keeps
# them at its root. Accept either so one script serves both layouts.
seed_bin=$seed
if test -d "$seed/bin"; then seed_bin=$seed/bin; fi
for name in xsh xshi xsht; do cp -L -- "$seed_bin/$name" "$work/context/bin/$name"; done
for name in kache mold; do
  tool_source=$(command -v "$name")
  cp -L -- "$tool_source" "$work/context/bin/$name"
  chmod 0755 "$work/context/bin/$name"
  printf 'declared seed tool %s: %s bytes\n' "$name" "$(stat -c '%s' "$work/context/bin/$name")"
done
# The frozen core tree keeps applets as *.xsh; the installed seed strips the
# suffix from commands and keeps library modules under lib/.
if test -d "$seed/core/lib"; then
  cp -R -- "$seed/core/." "$work/context/core/"
else
  cp -- "$seed"/core/*.xsh "$work/context/core/"
  cp -R -- "$seed/core/lib" "$work/context/core/lib"
fi
cp -- "$repo/pm.xsh" "$work/context/pm.xsh"
cp -R -- "$repo/pm" "$work/context/pm"
cp -R -- "$repo/tests/docker/fixtures/closed-build" "$work/context/cohort"
mkdir -p "$work/context/cohort/pm"
cp -- "$repo/pm/proof.xsh" "$work/context/cohort/pm/proof.xsh"
for hostile in cohort-hostile-read cohort-hostile-write cohort-hostile-tcp; do
  mkdir -p "$work/context/cohort/$hostile/pm"
  cp -- "$repo/pm/proof.xsh" "$work/context/cohort/$hostile/pm/proof.xsh"
done
cp -- "$repo/tests/docker/fixtures/closed-build/probe.c" "$work/context/probe.c"
printf 'host sentinel\n' > "$work/ambient/secret"
cp -- "$work/ambient/secret" "$work/ambient/libambient.so"
printf '#!/bin/false\n' > "$work/ambient/curl"
chmod +x "$work/ambient/curl"
docker image tag "$seed_image" "$seed_tag"
docker build --network none --pull=false --build-arg "SEED_IMAGE=$seed_tag" -f "$repo/tests/docker/closed_build.Dockerfile" -t "$image" "$work/context"
for tool in kache mold; do
  docker run --rm --user "$build_uid:$build_gid" --network none --read-only --cap-drop ALL --security-opt no-new-privileges --entrypoint "/bin/$tool" "$image" --version
done
# The closed cohort runs as the host UID with no capabilities, no new
# privileges, and no network. Only /scratch and the fresh /output store are
# writable. PM starts every package build child through linux.run_confined.
cohort_run() {
  LAPUTA_AMBIENT_POISON="host-secret-$1" HOME="$work/ambient/$1" LANG="poison-$1" TZ="poison-$1" PATH="$work/ambient:$PATH" LD_LIBRARY_PATH="$work/ambient" docker run --rm --name "$container" --user "$build_uid:$build_gid" --env "LAPUTA_SENTINEL_PATH=$work/ambient/secret" --env "LAPUTA_COHORT_SOURCE=/checkout-$1/packages/cohort-c/files/hello.c" --network none --read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 128 --ipc none --tmpfs /scratch:rw,exec,nosuid,nodev,mode=1777 --mount "type=bind,source=$work/output-$1,target=/output" --mount "type=bind,source=$work/context/cohort,target=/checkout-$1,readonly" "$image" "/checkout-$1" "${2:-cohort}"
}
exec 9< "$work/ambient/secret"
cohort_run one
cohort_run two
exec 9<&-
test "$(cat "$work/ambient/secret")" = 'host sentinel'
test "$(cat "$work/ambient/libambient.so")" = 'host sentinel'
mapfile -t first_receipts < <(fd --hidden --no-ignore --type f --glob artifact.json "$work/output-one")
mapfile -t second_receipts < <(fd --hidden --no-ignore --type f --glob artifact.json "$work/output-two")
test "${#first_receipts[@]}" = 3
test "${#second_receipts[@]}" = 3
receipt_named() {
  local package=$1
  shift
  local receipt
  for receipt in "$@"; do
    if test "$(jaq -r '.package_name' "$receipt")" = "$package"; then printf '%s\n' "$receipt"; fi
  done
}
for package in cohort-c cohort-rust cohort-xsh; do
  mapfile -t matching_first < <(receipt_named "$package" "${first_receipts[@]}")
  mapfile -t matching_second < <(receipt_named "$package" "${second_receipts[@]}")
  test "${#matching_first[@]}" = 1
  test "${#matching_second[@]}" = 1
  first=${matching_first[0]}
  second=${matching_second[0]}
  test "$(jaq -r '.key' "$first")" = "$(jaq -r '.key' "$second")"
  if ! cmp -- "${first%/*}/payload.tar.gz" "${second%/*}/payload.tar.gz"; then
    mkdir -p "$work/compare/$package/one" "$work/compare/$package/two"
    tar -xzf "${first%/*}/payload.tar.gz" -C "$work/compare/$package/one"
    tar -xzf "${second%/*}/payload.tar.gz" -C "$work/compare/$package/two"
    if diff -r -- "$work/compare/$package/one" "$work/compare/$package/two"; then printf 'payload archive metadata differs\n' >&2; fi
    exit 1
  fi
  test "$(jaq -r '.payload_sha256' "$first")" = "$(jaq -r '.payload_sha256' "$second")"
  jaq '{package_name, key, executor_sha256, payload_sha256}' "$first"
done
# Each hostile package escapes one declared boundary. A confined build must
# refuse it: the build fails, and the failure names a confinement denial rather
# than the escape succeeding.
for hostile in cohort-hostile-read cohort-hostile-write cohort-hostile-tcp; do
  mkdir -p "$work/output-$hostile"
  chmod 0777 "$work/output-$hostile"
  log="$work/$hostile.log"
  if cohort_run "$hostile" "$hostile" >"$log" 2>&1; then
    printf 'hostile cohort %s published; confinement did not refuse it\n' "$hostile" >&2
    cat "$log" >&2
    exit 1
  fi
  if ! grep -Eq 'Permission denied|confinement' "$log"; then
    printf 'hostile cohort %s failed without a confinement denial\n' "$hostile" >&2
    cat "$log" >&2
    exit 1
  fi
  if grep -q 'published' "$log"; then
    printf 'hostile cohort %s published despite the escape\n' "$hostile" >&2
    cat "$log" >&2
    exit 1
  fi
  printf 'hostile cohort %s refused under confinement\n' "$hostile"
done
# An unsupported kernel fails the spawn before a build child starts; it is never
# silently unconfined. Mask the Landlock syscalls with seccomp, as a kernel
# without Landlock answers ENOSYS, and require the confinement spawn failure.
mkdir -p "$work/output-nolandlock"
chmod 0777 "$work/output-nolandlock"
cat > "$work/no-landlock.json" <<'JSON'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": ["landlock_create_ruleset", "landlock_add_rule", "landlock_restrict_self"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 38
    }
  ]
}
JSON
log="$work/no-landlock.log"
if LAPUTA_AMBIENT_POISON="host-secret-nolandlock" HOME="$work/ambient/nolandlock" LANG="poison-nolandlock" TZ="poison-nolandlock" docker run --rm --name "$container" --user "$build_uid:$build_gid" --env "LAPUTA_SENTINEL_PATH=$work/ambient/secret" --env "LAPUTA_COHORT_SOURCE=/checkout-nolandlock/packages/cohort-c/files/hello.c" --network none --read-only --cap-drop ALL --security-opt no-new-privileges --security-opt "seccomp=$work/no-landlock.json" --pids-limit 128 --ipc none --tmpfs /scratch:rw,exec,nosuid,nodev,mode=1777 --mount "type=bind,source=$work/output-nolandlock,target=/output" --mount "type=bind,source=$work/context/cohort,target=/checkout-nolandlock,readonly" "$image" "/checkout-nolandlock" cohort >"$log" 2>&1; then
  printf 'a Landlock-less kernel published the cohort instead of failing the spawn\n' >&2
  cat "$log" >&2
  exit 1
fi
if ! grep -q 'confinement requires Landlock' "$log"; then
  printf 'a Landlock-less kernel failed without the confinement spawn error\n' >&2
  cat "$log" >&2
  exit 1
fi
if ! grep -q 'execute_run_confined_build' "$log"; then
  printf 'a Landlock-less kernel failed somewhere other than the confined spawn\n' >&2
  cat "$log" >&2
  exit 1
fi
# The build child prints this from the probe; its absence proves none started.
if grep -q 'closed build authority probes passed' "$log"; then
  printf 'a Landlock-less kernel ran a build child before failing\n' >&2
  cat "$log" >&2
  exit 1
fi
mapfile -t nolandlock_receipts < <(fd --hidden --no-ignore --type f --glob artifact.json "$work/output-nolandlock")
test "${#nolandlock_receipts[@]}" = 0
printf 'unsupported kernel refused confinement before any build child\n'
printf 'closed build cohort passed; seed %s\n' "$seed_image"
