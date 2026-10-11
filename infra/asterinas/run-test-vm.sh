#!/usr/bin/env bash
set -euo pipefail

[[ $# == 6 ]] || {
    printf 'usage: run-test-vm.sh FIRECRACKER CONFIG CONSOLE_LOG FIRECRACKER_LOG XSH_TEST_SELECTION MAX_POLLS\n' >&2
    exit 2
}

firecracker_bin="$1"
firecracker_config="$2"
console_log="$3"
firecracker_log="$4"
test_selection="$5"
max_polls="$6"
firecracker_pid=""

[[ -x "$firecracker_bin" ]] || {
    printf 'asterinas-test: Firecracker is not executable: %s\n' "$firecracker_bin" >&2
    exit 1
}
[[ "$max_polls" =~ ^[1-9][0-9]*$ ]] || {
    printf 'asterinas-test: invalid guest completion poll count: %s\n' "$max_polls" >&2
    exit 2
}

fail() {
    printf 'asterinas-test: %s\n' "$*" >&2
    if [[ -s "$console_log" ]]; then
        printf '\n--- Asterinas guest console ---\n' >&2
        tail -n 80 "$console_log" >&2 || true
    fi
    if [[ -s "$firecracker_log" ]]; then
        printf '\n--- Firecracker diagnostics ---\n' >&2
        tail -n 60 "$firecracker_log" >&2 || true
    fi
    exit 1
}

stop_firecracker() {
    [[ -n "$firecracker_pid" ]] || return 0
    if kill -0 "$firecracker_pid" 2>/dev/null; then
        kill -TERM "$firecracker_pid" 2>/dev/null || true
        for _ in {1..50}; do
            local state
            state="$(ps -o stat= -p "$firecracker_pid" 2>/dev/null | tr -d ' ' || true)"
            [[ -z "$state" || "$state" == Z* ]] && break
            sleep 0.1
        done
        state="$(ps -o stat= -p "$firecracker_pid" 2>/dev/null | tr -d ' ' || true)"
        if [[ -n "$state" && "$state" != Z* ]]; then
            kill -KILL "$firecracker_pid" 2>/dev/null || true
        fi
    fi
    wait "$firecracker_pid" 2>/dev/null || true
    firecracker_pid=""
}

cleanup() {
    stop_firecracker
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

: > "$console_log"
: > "$firecracker_log"
"$firecracker_bin" --no-api --config-file "$firecracker_config" \
    </dev/null >"$console_log" 2>"$firecracker_log" &
firecracker_pid=$!

complete=false
for ((attempt = 0; attempt < max_polls; attempt++)); do
    if grep -Fq LAPUTA_ASTERINAS_TEST_FAILED "$console_log"; then
        fail 'guest reported a failed Laputa proof'
    fi
    if grep -Eq 'Kernel panic|panicked at|Uncaught panic|failed to run the init process' "$console_log"; then
        fail 'Asterinas reported a kernel or init failure'
    fi
    if grep -Fq LAPUTA_ASTERINAS_TEST_OK "$console_log"; then
        complete=true
        break
    fi
    state="$(ps -o stat= -p "$firecracker_pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ -z "$state" || "$state" == Z* ]]; then
        vm_status=0
        wait "$firecracker_pid" || vm_status=$?
        firecracker_pid=""
        fail "Firecracker exited with status $vm_status before the guest completion marker"
    fi
    sleep 0.2
done
[[ "$complete" == true ]] || fail 'timed out waiting for the Laputa guest completion marker'

if [[ -n "$test_selection" ]]; then
    grep -Fq "LAPUTA_ASTERINAS_XSH_TEST_START $test_selection" "$console_log" || \
        fail "guest did not start the requested XSH test selection: $test_selection"
    grep -Fq LAPUTA_ASTERINAS_XSH_TEST_OK "$console_log" || \
        fail 'guest did not report the selected XSH test module passing'
fi
