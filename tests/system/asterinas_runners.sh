#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
infra="$repo_root/infra/asterinas"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/laputa-asterinas-runners.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
xsh_bin="$(command -v xsh)"

fail() { printf 'asterinas runners: %s\n' "$*" >&2; exit 1; }

wait_for_file() {
    local file="$1" tick
    for ((tick = 0; tick < 200; tick++)); do
        [[ -s "$file" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for $file"
}

wait_for_exit() {
    local pid="$1" tick
    for ((tick = 0; tick < 400; tick++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.05
    done
    return 1
}

expect_gone() {
    local pid="$1" what="$2"
    wait_for_exit "$pid" || { kill -KILL "$pid" 2>/dev/null || true; fail "$what is still running"; }
}

expect_status() {
    local pid="$1" expected="$2" what="$3" status=0
    wait "$pid" || status=$?
    [[ "$status" == "$expected" ]] || fail "$what returned $status, expected $expected"
}

fake_bin="$scratch/bin"
docker_state="$scratch/docker-state"
mkdir -p "$fake_bin" "$docker_state"
cat > "$fake_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
    rm)
        [[ -e "$FAKE_DOCKER_STATE/$3" ]] || exit 1
        rm -f -- "$FAKE_DOCKER_STATE/$3"
        ;;
    run)
        name=""
        for ((index = 1; index <= $#; index++)); do
            [[ "${!index}" != --name ]] || { next=$((index + 1)); name="${!next}"; }
        done
        if [[ -n "$name" && -n "${FAKE_DOCKER_CREATE_DELAY:-}" ]]; then
            ( sleep "$FAKE_DOCKER_CREATE_DELAY"; : > "$FAKE_DOCKER_STATE/$name" ) > /dev/null 2>&1 &
        elif [[ -n "$name" ]]; then
            : > "$FAKE_DOCKER_STATE/$name"
        fi
        if [[ -n "${FAKE_DOCKER_RUN_PID:-}" ]]; then
            printf '%s\n' "$$" > "$FAKE_DOCKER_RUN_PID"
            exec sleep 300
        fi
        ;;
    image)
        printf 'sha256:fake\n'
        ;;
esac
DOCKER
chmod 755 "$fake_bin/docker"
export PATH="$fake_bin:$PATH" FAKE_DOCKER_STATE="$docker_state"

harness="$scratch/harness.sh"
cat > "$harness" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
source "$HARNESS_INFRA/run-cancellable.sh"
mode="$1"
shift
case "$mode" in
    sleep) run_cancellable "${HARNESS_CONTAINER:-}" bash -c 'printf "%s\n" "$$" > "$1"; exec sleep 300' _ "$1" ;;
    exit) run_cancellable "${HARNESS_CONTAINER:-}" bash -c 'exit 7' ;;
    docker) run_cancellable "$1" docker run --name "$1" ;;
    nested) run_cancellable "" bash "$0" sleep "$1" ;;
    spawn_race)
        set -T
        trap '[[ $BASH_COMMAND != "cancellable_child=\$!" ]] || kill -TERM $$' DEBUG
        run_cancellable "" bash -c 'printf "%s\n" "$$" > "$1"; exec sleep 300' _ "$1"
        ;;
esac
HARNESS
export HARNESS_INFRA="$infra"

start_harness() {
    env --default-signal=INT "$@" &
    harness_pid=$!
}

pidfile="$scratch/sleeper.pid"

rm -f "$pidfile"
: > "$docker_state/case-1"
HARNESS_CONTAINER=case-1 start_harness bash "$harness" sleep "$pidfile"
wait_for_file "$pidfile"
sleeper="$(cat "$pidfile")"
kill -TERM "$harness_pid"
expect_status "$harness_pid" 143 "a terminated runner"
expect_gone "$sleeper" "the child of a terminated runner"
[[ ! -e "$docker_state/case-1" ]] || fail "a terminated runner left its container"

rm -f "$pidfile"
start_harness bash "$harness" sleep "$pidfile"
wait_for_file "$pidfile"
sleeper="$(cat "$pidfile")"
kill -INT "$harness_pid"
expect_status "$harness_pid" 130 "an interrupted runner"
expect_gone "$sleeper" "the child of an interrupted runner"

: > "$docker_state/case-2"
status=0
HARNESS_CONTAINER=case-2 bash "$harness" exit || status=$?
[[ "$status" == 7 ]] || fail "a finished runner returned $status, expected the child's status 7"
[[ ! -e "$docker_state/case-2" ]] || fail "a finished runner left its container"

rm -f "$pidfile"
start_harness bash "$harness" nested "$pidfile"
outer_pid=$harness_pid
wait_for_file "$pidfile"
sleeper="$(cat "$pidfile")"
inner_pid="$(awk '{print $4}' "/proc/$sleeper/stat")"
[[ "$inner_pid" != "$outer_pid" ]] || fail "the nested runner is not below the outer one"
kill -INT "$inner_pid"
expect_gone "$sleeper" "the child of an interrupted nested runner"
wait_for_exit "$inner_pid" || fail "an interrupted nested runner is still running"
expect_status "$outer_pid" 130 "the outer runner of an interrupted nested runner"

rm -f "$pidfile"
start_harness bash "$harness" spawn_race "$pidfile"
expect_status "$harness_pid" 143 "a runner terminated while it spawned its child"
sleep 0.5
if [[ -s "$pidfile" ]]; then
    sleeper="$(cat "$pidfile")"
    expect_gone "$sleeper" "the child of a runner terminated while it spawned it"
fi

rm -f "$docker_state"/* "$scratch/client.pid"
FAKE_DOCKER_CREATE_DELAY=0.6 FAKE_DOCKER_RUN_PID="$scratch/client.pid" start_harness bash "$harness" docker case-3
wait_for_file "$scratch/client.pid"
sleep 0.15
kill -TERM "$harness_pid"
expect_status "$harness_pid" 143 "a runner terminated before its container existed"
sleep 1.2
[[ ! -e "$docker_state/case-3" ]] || fail "a container created after the runner was terminated survived"

cohort_root="$scratch/cohort"
mkdir -p "$cohort_root/infra/asterinas" "$cohort_root/.work/tmp" "$cohort_root/guest/asterinas/clock"
cp "$infra/run-cancellable.sh" "$infra/qualify-cohort.sh" "$cohort_root/infra/asterinas/"
for stub in run-witness run-guest-case; do
    cat > "$cohort_root/infra/asterinas/$stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s start\n' "$1" >> "$COHORT_TRACE"
case "${COHORT_STUB:-quick}" in
    quick) sleep 0.3 ;;
    hold) printf '%s\n' "$$" >> "$COHORT_PIDS"; exec sleep 300 ;;
    stubborn) trap '' TERM INT; printf '%s\n' "$$" >> "$COHORT_PIDS"; while :; do sleep 1; done ;;
esac
printf '%s end\n' "$1" >> "$COHORT_TRACE"
STUB
done
export COHORT_TRACE="$scratch/cohort.trace" COHORT_PIDS="$scratch/cohort.pids"
cohort_runner="$cohort_root/infra/asterinas/qualify-cohort.sh"

: > "$COHORT_TRACE"
COHORT_STUB=quick bash "$cohort_runner" clock-abi both '' > "$scratch/cohort-serial.log" 2>&1 || { cat "$scratch/cohort-serial.log" >&2; fail "the quick cohort failed"; }
[[ "$(cat "$COHORT_TRACE")" == "linux start
linux end
asterinas start
asterinas end" ]] || fail "the backends did not run one after the other: $(tr '\n' ',' < "$COHORT_TRACE")"

for signal in TERM INT; do
    expected=143
    [[ "$signal" == TERM ]] || expected=130
    : > "$COHORT_TRACE"
    : > "$COHORT_PIDS"
    COHORT_STUB=hold start_harness bash "$cohort_runner" clock-abi both ''
    wait_for_file "$COHORT_PIDS"
    stub_pid="$(head -n 1 "$COHORT_PIDS")"
    kill -"$signal" "$harness_pid"
    expect_status "$harness_pid" "$expected" "a cohort that received SIG$signal"
    expect_gone "$stub_pid" "the case runner of a cohort that received SIG$signal"
    compgen -G "$cohort_root/.work/tmp/clock-abi.*" > /dev/null && fail "a cohort that received SIG$signal left its results"
done

: > "$COHORT_PIDS"
LAPUTA_CANCEL_GRACE_SECONDS=6 COHORT_STUB=stubborn start_harness bash -c "source '$infra/run-cancellable.sh'; run_cancellable '' bash '$cohort_runner' clock-abi both ''"
wait_for_file "$COHORT_PIDS"
stub_pid="$(head -n 1 "$COHORT_PIDS")"
kill -TERM "$harness_pid"
expect_status "$harness_pid" 143 "an outer runner above a cohort whose case runner ignores TERM"
expect_gone "$stub_pid" "a case runner that ignores TERM"
compgen -G "$cohort_root/.work/tmp/clock-abi.*" > /dev/null && fail "a cohort stopped by escalation left its results"

runner_root="$scratch/runner"
bundle="$runner_root/.out/asterinas-firecracker/builds/fake"
mkdir -p "$runner_root/infra/asterinas" "$runner_root/.work/tmp" "$bundle" "$runner_root/.out/host/x86_64" \
    "$runner_root/.out/asterinas-firecracker/bin" "$runner_root/asterinas/test/initramfs/src/regression/fake" \
    "$runner_root/guest/asterinas/fake"
cp "$infra/run-cancellable.sh" "$infra/run-guest-case.sh" "$infra/run-witness.sh" "$infra/run-test-vm.sh" \
    "$infra/check-guest-output.xsh" "$infra/guest_protocol.xsh" "$runner_root/infra/asterinas/"
printf '#!/usr/bin/env bash\n[[ -s "$2" ]]\n' > "$runner_root/infra/asterinas/inject-guest-file.sh"
printf '0.0.0\n' > "$runner_root/asterinas/DOCKER_IMAGE_VERSION"
printf 'int main(void) { return 0; }\n' > "$runner_root/asterinas/test/initramfs/src/regression/fake/witness.c"
printf '#!/bin/xsh --\n' > "$runner_root/guest/asterinas/fake/entry.xsh"
ln -s "$xsh_bin" "$runner_root/.out/host/x86_64/xsh"
ln -s builds/fake "$runner_root/.out/asterinas-firecracker/current"
printf 'root image\n' > "$bundle/laputa-root.ext2"
jaq -n --arg root "$scratch/runtime-root.ext2" '{"machine-config": {mem_size_mib: 1024}, drives: [{path_on_host: $root}]}' > "$bundle/firecracker.json"
cat > "$runner_root/.out/asterinas-firecracker/bin/firecracker" <<'FIRECRACKER'
#!/usr/bin/env bash
[[ -z "${FAKE_FIRECRACKER_EXITS:-}" ]] || exit 0
cat "$FAKE_CONSOLE"
exec sleep 30
FIRECRACKER
chmod 755 "$runner_root/.out/asterinas-firecracker/bin/firecracker"

mapfile -t markers < <(sed -n '/^export const guest_success_markers = \[/,/^\]/p' "$infra/guest_protocol.xsh" | rg -o 'LAPUTA_ASTERINAS_[A-Z0-9_]+')
(( ${#markers[@]} > 10 )) || fail "no guest markers found in guest_protocol.xsh"
[[ "${markers[-1]}" == LAPUTA_ASTERINAS_TEST_OK ]] || fail "the completion marker is not the last guest marker"

write_console() {
    local kind="$1" console="$2" skipped="${3:-}" marker
    : > "$console"
    for marker in "${markers[@]::${#markers[@]}-1}" "LAPUTA_ASTERINAS_${kind}_START fake" "LAPUTA_ASTERINAS_${kind}_OK" "${markers[-1]}"; do
        [[ "$marker" == "$skipped" ]] || printf '%s\n' "$marker" >> "$console"
    done
}

run_runner() {
    local kind="$1" expected="$2" label="$3" console="$4"
    local result="$scratch/result-$kind-${label// /-}" status=0
    rm -rf "$result"
    mkdir -p "$result"
    if [[ "$kind" == CASE ]]; then
        FAKE_CONSOLE="$console" LAPUTA_CASE_TIMEOUT=1 bash "$runner_root/infra/asterinas/run-guest-case.sh" asterinas \
            "$runner_root/guest/asterinas/fake" smoke "$result" > "$result.out" 2>&1 || status=$?
    else
        printf 'witness\n' > "$result/witness"
        FAKE_CONSOLE="$console" bash "$runner_root/infra/asterinas/run-witness.sh" asterinas \
            "$runner_root/asterinas/test/initramfs/src/regression/fake/witness.c" "$result" > "$result.out" 2>&1 || status=$?
    fi
    [[ "$status" == "$expected" ]] || { cat "$result.out" >&2; fail "the $kind runner returned $status for $label, expected $expected"; }
}

for kind in CASE WITNESS; do
    write_console "$kind" "$scratch/$kind.full"
    run_runner "$kind" 0 "a complete guest run" "$scratch/$kind.full"

    write_console "$kind" "$scratch/$kind.partial" LAPUTA_ASTERINAS_COLDPLUG_OK
    run_runner "$kind" 1 "a run missing a boot marker" "$scratch/$kind.partial"
    rg -q 'LAPUTA_ASTERINAS_COLDPLUG_OK' "$scratch/result-$kind-a-run-missing-a-boot-marker/check.log" \
        || fail "the $kind runner did not name the missing marker"

    write_console "$kind" "$scratch/$kind.unfinished" LAPUTA_ASTERINAS_${kind}_OK
    run_runner "$kind" 1 "a run that never finished" "$scratch/$kind.unfinished"

    { cat "$scratch/$kind.full"; printf 'LAPUTA_ASTERINAS_TEST_FAILED proof: expected\n'; } > "$scratch/$kind.failed"
    run_runner "$kind" 1 "a run that reports failure" "$scratch/$kind.failed"

    : > "$scratch/$kind.silent"
    FAKE_FIRECRACKER_EXITS=1 run_runner "$kind" 1 "a VMM that exits at once" "$scratch/$kind.silent"
done
run_runner CASE 1 "a guest that never completes" "$scratch/CASE.silent"

rm -f "$docker_state"/* "$scratch/client.pid"
FAKE_DOCKER_RUN_PID="$scratch/client.pid" LAPUTA_GUEST_NETWORK=tap start_harness bash "$runner_root/infra/asterinas/run-guest-case.sh" \
    asterinas "$runner_root/guest/asterinas/fake" tapped "$scratch/result-tapped"
case_runner=$harness_pid
wait_for_file "$scratch/client.pid"
[[ -e "$docker_state/laputa-asterinas-case-$case_runner" ]] || fail "the TAP case runner did not name its container laputa-asterinas-case-PID"
kill -TERM "$case_runner"
expect_status "$case_runner" 143 "a terminated TAP case runner"
expect_gone "$(cat "$scratch/client.pid")" "the container client of a terminated TAP case runner"
[[ ! -e "$docker_state/laputa-asterinas-case-$case_runner" ]] || fail "a terminated TAP case runner left its container"

resources_root="$scratch/resources"
bundle="$resources_root/.out/asterinas-firecracker/builds/fake"
mkdir -p "$resources_root/infra/asterinas" "$resources_root/.work/tmp" "$bundle"
cp "$infra/run-cancellable.sh" "$infra/resources.sh" "$resources_root/infra/asterinas/"
ln -s builds/fake "$resources_root/.out/asterinas-firecracker/current"
printf '{"machine-config":{"vcpu_count":2,"mem_size_mib":768}}\n' > "$bundle/firecracker.json"
head -c 4096 /dev/zero > "$bundle/kernel.elf"
head -c 100 /dev/zero > "$bundle/laputa-initramfs.cpio.gz"
head -c 8192 /dev/zero > "$bundle/laputa-root.ext2"
cat > "$scratch/firecracker" <<'VMM'
#!/bin/bash
sleep 1
VMM
chmod 755 "$scratch/firecracker"
cat > "$resources_root/infra/asterinas/qualify.sh" <<QUALIFY
#!/usr/bin/env bash
"$scratch/firecracker" --config-file "$bundle/firecracker.json"
QUALIFY
for gate in 0 75; do
    PERF_GATE_MAX_LOAD=$([[ "$gate" == 0 ]] && echo 1000000 || echo 0) bash "$resources_root/infra/asterinas/resources.sh" asterinas boot > "$scratch/resources-$gate.out" 2>&1 \
        || { cat "$scratch/resources-$gate.out" >&2; fail "the resource measurement failed with gate status $gate"; }
    rg -q 'backend=asterinas case=boot vmm=firecracker kernel_bytes=4096 initramfs_bytes=100 root_bytes=8192 .* memory_mib=768 peak_rss_kib=[1-9][0-9]*' "$scratch/resources-$gate.out" \
        || { cat "$scratch/resources-$gate.out" >&2; fail "the resource record is wrong with gate status $gate"; }
done
expect_resources() {
    local gate="$1" pattern="$2" what="$3"
    rg -q -- "$pattern" "$scratch/resources-$gate.out" || { cat "$scratch/resources-$gate.out" >&2; fail "$what"; }
}
expect_resources 0 'cpu_user_ms=[0-9]+ cpu_sys_ms=[0-9]+' "a quiet host did not record the CPU time"
expect_resources 75 'cpu=deferred' "a busy host did not defer the CPU time"
expect_resources 75 'perf gate deferred: host busy' "a busy host did not report the deferred gate"
! rg -q 'cpu_user_ms' "$scratch/resources-75.out" || fail "a busy host recorded a CPU time"
! rg -q 'perf gate deferred' "$scratch/resources-0.out" || fail "a quiet host deferred the time gate"

printf 'Asterinas runners clean up, run serially and reject incomplete guest output.\n'
