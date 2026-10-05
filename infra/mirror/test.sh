#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/laputa-mirror-tests.XXXXXX") || exit 1
POSIX_SH=/bin/sh
[ ! -x /bin/dash ] || POSIX_SH=/bin/dash
STAGE_A=
STAGE_B=
STAGE_BAD=

cleanup() {
    [ -z "$STAGE_A" ] || rm -rf "$STAGE_A"
    [ -z "$STAGE_B" ] || rm -rf "$STAGE_B"
    [ -z "$STAGE_BAD" ] || rm -rf "$STAGE_BAD"
    rm -rf "$TEST_DIR"
}
trap cleanup 0 HUP INT TERM

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'ok  %s\n' "$*"
}

contains() {
    if ! grep -F "$2" "$1" >/dev/null; then
        cat "$1" >&2
        fail "expected '$2' in $1"
    fi
}

not_contains() {
    if grep -F "$2" "$1" >/dev/null; then
        fail "did not expect '$2' in $1"
    fi
}

assert_equal() {
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

FAKE_BIN=$TEST_DIR/bin
REMOTE_BIN=$TEST_DIR/remote-bin
mkdir -p "$FAKE_BIN" "$REMOTE_BIN"

cat >"$FAKE_BIN/mv" <<'SH'
#!/bin/sh
set -eu
if [ "${1-}" = -Tf ]; then
    printf 'atomic-replace\n' >>"$FAKE_ATOMIC_LOG"
    shift
    [ ! -L "$2" ] || rm -f "$2"
    exec /bin/mv -f "$@"
fi
exec /bin/mv "$@"
SH

cat >"$FAKE_BIN/flock" <<'SH'
#!/bin/sh
exit 0
SH

cat >"$FAKE_BIN/sleep" <<'SH'
#!/bin/sh
exit 0
SH

cat >"$FAKE_BIN/systemd-sysusers" <<'SH'
#!/bin/sh
printf 'sysusers\n' >>"$FAKE_SYSTEMD_LOG"
SH

cat >"$FAKE_BIN/systemd-analyze" <<'SH'
#!/bin/sh
exit 0
SH

cat >"$FAKE_BIN/journalctl" <<'SH'
#!/bin/sh
exit 0
SH

cat >"$FAKE_BIN/systemctl" <<'SH'
#!/bin/sh
set -eu
STATE=$FAKE_SYSTEMD_STATE
LOG=$FAKE_SYSTEMD_LOG
action=${1-}
if [ "$action" = --version ]; then
    printf 'systemd 255\n'
    exit 0
fi
shift || :
case "$action" in
    show)
        printf '%s\n' "${FAKE_CLOUDFLARED_FRAGMENT-}"
        ;;
    is-enabled)
        service=$1
        [ -f "$STATE/enabled.$service" ]
        ;;
    is-active)
        service=$1
        [ -f "$STATE/active.$service" ]
        ;;
    enable)
        service=$1
        : >"$STATE/enabled.$service"
        printf 'enable %s\n' "$service" >>"$LOG"
        ;;
    disable)
        if [ "${1-}" = --now ]; then
            shift
            service=$1
            rm -f "$STATE/active.$service"
        else
            service=$1
        fi
        rm -f "$STATE/enabled.$service"
        printf 'disable %s\n' "$service" >>"$LOG"
        ;;
    start)
        service=$1
        : >"$STATE/active.$service"
        printf 'start %s\n' "$service" >>"$LOG"
        ;;
    stop)
        service=$1
        rm -f "$STATE/active.$service"
        printf 'stop %s\n' "$service" >>"$LOG"
        ;;
    restart)
        service=$1
        : >"$STATE/active.$service"
        printf 'restart %s\n' "$service" >>"$LOG"
        ;;
    daemon-reload)
        printf 'daemon-reload\n' >>"$LOG"
        ;;
    *)
        printf 'unexpected systemctl operation: %s\n' "$action" >&2
        exit 1
        ;;
esac
SH

cat >"$FAKE_BIN/curl" <<'SH'
#!/bin/sh
set -eu
count=0
[ ! -f "$FAKE_CURL_COUNT_FILE" ] || count=$(cat "$FAKE_CURL_COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_CURL_COUNT_FILE"
if [ "$count" -le "${FAKE_CURL_FAIL_FIRST-0}" ]; then
    exit 22
fi
exit 0
SH

cat >"$FAKE_BIN/cf" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FAKE_CF_LOG"
case " $* " in
    *' r2 buckets create '*|*' r2 objects bulk-delete '*|*' tunnels create '*|*' tunnels config update '*|*' dns records create '*|*' dns records update '*|*' tunnels delete '*)
        printf '%s\n' "$*" >>"$FAKE_CF_MUTATIONS"
        ;;
esac
if [ "${1-}" = accounts ] && [ "${2-}" = list ]; then
    printf '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"test"}]\n'
elif [ "${1-}" = zones ] && [ "${2-}" = list ]; then
    zone_name=
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --name ]; then shift; zone_name=${1-}; break; fi
        shift
    done
    if [ "$zone_name" = example.com ]; then
        printf '[{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"example.com","status":"active","account":{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]\n'
    else
        printf '[]\n'
    fi
elif [ "${1-}" = r2 ] && [ "${2-}" = buckets ] && [ "${3-}" = list ]; then
    printf '{"buckets":[{"name":"laputa-mirror"}]}\n'
elif [ "${1-}" = r2 ] && [ "${2-}" = buckets ] && [ "${3-}" = jobs ] && [ "${4-}" = list ]; then
    if [ "${FAKE_CF_EMPTY_MODE-}" = active-job ]; then
        printf '{"jobs":[{"id":"existing-job","status":"RUNNING"}]}\n'
    else
        printf '{"jobs":[]}\n'
    fi
elif [ "${1-}" = r2 ] && [ "${2-}" = buckets ] && [ "${3-}" = jobs ] && [ "${4-}" = get ]; then
    count=0
    [ ! -f "$FAKE_CF_JOB_POLL_COUNT_FILE" ] || count=$(cat "$FAKE_CF_JOB_POLL_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_CF_JOB_POLL_COUNT_FILE"
    if [ "$count" -eq 1 ]; then
        printf '{"id":"empty-job","status":"RUNNING"}\n'
    else
        printf '{"id":"empty-job","status":"COMPLETED"}\n'
    fi
elif [ "${1-}" = r2 ] && [ "${2-}" = objects ] && [ "${3-}" = list ]; then
    count=0
    [ ! -f "$FAKE_CF_OBJECT_LIST_COUNT_FILE" ] || count=$(cat "$FAKE_CF_OBJECT_LIST_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_CF_OBJECT_LIST_COUNT_FILE"
    if { [ "${FAKE_CF_EMPTY_MODE-}" = async ] || [ "${FAKE_CF_EMPTY_MODE-}" = active-job ]; } && [ "$count" -eq 1 ]; then
        printf '[{"key":"old-package.tar.zst"}]\n'
    else
        printf '[]\n'
    fi
elif [ "${1-}" = r2 ] && [ "${2-}" = objects ] && [ "${3-}" = bulk-delete ]; then
    if [ "${FAKE_CF_EMPTY_MODE-}" = async ]; then
        printf '{"id":"empty-job","status":"ENQUEUED"}\n'
    else
        printf 'unexpected R2 bulk delete in mode %s\n' "${FAKE_CF_EMPTY_MODE-}" >&2
        exit 1
    fi
elif [ "${1-}" = tunnels ] && [ "${2-}" = list ]; then
    printf '[{"id":"11111111-2222-3333-4444-555555555555","name":"laputa-mirror","account_tag":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","deleted_at":null,"config_src":"cloudflare","status":"healthy"}]\n'
elif [ "${1-}" = tunnels ] && [ "${2-}" = config ] && [ "${3-}" = get ]; then
    printf '{"config":{"ingress":[{"hostname":"mirror.example.com","service":"http://%s"},{"service":"http_status:404"}]}}\n' "${MIRROR_LISTEN_ADDR-127.0.0.1:3000}"
elif [ "${1-}" = dns ] && [ "${2-}" = records ] && [ "${3-}" = list ]; then
    if [ "${FAKE_CF_MODE-}" = conflict ]; then
        printf '[{"id":"record-1","name":"mirror.example.com","type":"A","content":"192.0.2.1","proxied":true}]\n'
    else
        printf '[{"id":"record-1","name":"mirror.example.com","type":"CNAME","content":"11111111-2222-3333-4444-555555555555.cfargotunnel.com","proxied":true}]\n'
    fi
else
    printf 'unexpected cf operation: %s\n' "$*" >&2
    exit 1
fi
SH

cat >"$FAKE_BIN/ssh" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
PATH=$FAKE_REMOTE_PATH
export PATH
if [ -x /bin/dash ]; then exec /bin/dash -s; fi
exec /bin/sh -s
SH

cat >"$FAKE_BIN/docker" <<'SH'
#!/bin/sh
exit 0
SH

cat >"$FAKE_BIN/deno" <<'SH'
#!/bin/sh
exit 0
SH

cat >"$FAKE_BIN/node" <<'SH'
#!/bin/sh
exit 0
SH

cat >"$FAKE_BIN/dpkg-query" <<'SH'
#!/bin/sh
exit 1
SH

cat >"$FAKE_BIN/dpkg" <<'SH'
#!/bin/sh
printf 'unexpected dpkg invocation\n' >&2
exit 1
SH

chmod 755 "$FAKE_BIN"/*

for command_name in tar install cmp readlink find grep ln; do
    command_path=$(command -v "$command_name") || fail "test needs $command_name"
    ln -s "$command_path" "$REMOTE_BIN/$command_name"
done
ln -s "$FAKE_BIN/mv" "$REMOTE_BIN/mv"
ln -s "$FAKE_BIN/curl" "$REMOTE_BIN/curl"
ln -s "$FAKE_BIN/flock" "$REMOTE_BIN/flock"
ln -s "$FAKE_BIN/sleep" "$REMOTE_BIN/sleep"
ln -s "$FAKE_BIN/systemctl" "$REMOTE_BIN/systemctl"
ln -s "$FAKE_BIN/systemd-analyze" "$REMOTE_BIN/systemd-analyze"
cat >"$REMOTE_BIN/id" <<'SH'
#!/bin/sh
printf '0\n'
SH
cat >"$REMOTE_BIN/uname" <<'SH'
#!/bin/sh
case "${1-}" in -s) printf 'Linux\n' ;; -m) printf 'x86_64\n' ;; *) exit 1 ;; esac
SH
chmod 755 "$REMOTE_BIN/id" "$REMOTE_BIN/uname"

CF_LOG=$TEST_DIR/cf.log
CF_MUTATIONS=$TEST_DIR/cf-mutations.log
SSH_LOG=$TEST_DIR/ssh.log
: >"$CF_LOG"
: >"$CF_MUTATIONS"
: >"$SSH_LOG"

cat >"$TEST_DIR/missing-secret.env" <<'ENV'
CLOUDFLARE_API_TOKEN='local-test-token'
MIRROR_ALLOWED_USERS='publisher'
ENV
if env -i HOME="$TEST_DIR/home" PATH="$FAKE_BIN:$PATH" MIRROR_DEPLOY_ENV="$TEST_DIR/missing-secret.env" \
    FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" FAKE_SSH_LOG="$SSH_LOG" \
    "$POSIX_SH" "$SCRIPT_DIR/deploy.sh" --preflight >"$TEST_DIR/missing-secret.log" 2>&1; then
    fail 'missing R2 credentials unexpectedly passed preflight'
fi
contains "$TEST_DIR/missing-secret.log" 'set S3_ACCESS_KEY_ID or S3_ACCESS_KEY_ID_FILE'
[ ! -s "$CF_LOG" ] || fail 'Cloudflare was queried before missing local secrets were rejected'
[ ! -s "$SSH_LOG" ] || fail 'SSH was invoked before missing local secrets were rejected'
pass 'missing secret fails before Cloudflare or SSH access'

cat >"$TEST_DIR/incomplete-jwt.env" <<'ENV'
S3_ACCESS_KEY_ID='test-access-key'
S3_SECRET_ACCESS_KEY='test-s3-secret'
MIRROR_ALLOWED_USERS='publisher'
JWT_JWKS_URL='https://identity.example.com/jwks'
ENV
: >"$CF_LOG"
: >"$SSH_LOG"
if env -i HOME="$TEST_DIR/home" PATH="$FAKE_BIN:$PATH" MIRROR_DEPLOY_ENV="$TEST_DIR/incomplete-jwt.env" \
    FAKE_CF_LOG="$CF_LOG" FAKE_SSH_LOG="$SSH_LOG" \
    "$POSIX_SH" "$SCRIPT_DIR/deploy.sh" --preflight >"$TEST_DIR/incomplete-jwt.log" 2>&1; then
    fail 'incomplete JWT configuration unexpectedly passed preflight'
fi
contains "$TEST_DIR/incomplete-jwt.log" 'JWT_ISSUER is required when JWT_JWKS_URL is set'
[ ! -s "$CF_LOG" ] || fail 'Cloudflare was queried before incomplete JWT settings were rejected'
[ ! -s "$SSH_LOG" ] || fail 'SSH was invoked before incomplete JWT settings were rejected'
pass 'incomplete JWT configuration fails before Cloudflare or SSH access'

cat >"$TEST_DIR/complete.env" <<'ENV'
CLOUDFLARE_API_TOKEN='local-test-token'
CF_ACCOUNT_ID='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
S3_ACCESS_KEY_ID='test-access-key-secret'
S3_SECRET_ACCESS_KEY='test-s3-secret'
MIRROR_ALLOWED_USERS='publisher'
MIRROR_HOSTNAME='mirror.example.com'
DEPLOY_HOST='config-target'
ENV
: >"$CF_LOG"
: >"$CF_MUTATIONS"
: >"$SSH_LOG"
if env -i HOME="$TEST_DIR/home" PATH="$FAKE_BIN:$PATH" MIRROR_DEPLOY_ENV="$TEST_DIR/complete.env" \
    FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" FAKE_SSH_LOG="$SSH_LOG" \
    FAKE_REMOTE_PATH="$REMOTE_BIN" FAKE_SYSTEMD_LOG="$TEST_DIR/remote-preflight-systemd.log" \
    "$POSIX_SH" "$SCRIPT_DIR/deploy.sh" --preflight >"$TEST_DIR/remote-prerequisite.log" 2>&1; then
    fail 'missing remote prerequisite unexpectedly passed preflight'
fi
contains "$TEST_DIR/remote-prerequisite.log" 'remote preflight: missing remote prerequisite: systemd-sysusers'
contains "$SSH_LOG" 'config-target'
pass 'missing remote prerequisite reports the exact host requirement'

: >"$SSH_LOG"
if env -i HOME="$TEST_DIR/home" PATH="$FAKE_BIN:$PATH" MIRROR_DEPLOY_ENV="$TEST_DIR/complete.env" \
    FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" \
    FAKE_SSH_LOG="$SSH_LOG" FAKE_REMOTE_PATH="$REMOTE_BIN" \
    FAKE_SYSTEMD_LOG="$TEST_DIR/make-remote-preflight-systemd.log" \
    make --no-print-directory preflight-mirror >"$TEST_DIR/make-host-default.log" 2>&1; then
    fail 'missing remote prerequisite unexpectedly passed through Make'
fi
contains "$SSH_LOG" 'config-target'
pass 'Make leaves DEPLOY_HOST unset so the deployment environment file supplies it'

: >"$SSH_LOG"
if env -i HOME="$TEST_DIR/home" PATH="$FAKE_BIN:$PATH" MIRROR_DEPLOY_ENV="$TEST_DIR/complete.env" \
    DEPLOY_HOST=override@target FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" \
    FAKE_SSH_LOG="$SSH_LOG" FAKE_REMOTE_PATH="$REMOTE_BIN" \
    FAKE_SYSTEMD_LOG="$TEST_DIR/remote-preflight-systemd.log" \
    "$POSIX_SH" "$SCRIPT_DIR/deploy.sh" --preflight >"$TEST_DIR/host-override.log" 2>&1; then
    fail 'missing remote prerequisite unexpectedly passed with a host override'
fi
contains "$SSH_LOG" 'override@target'
not_contains "$SSH_LOG" 'config-target'
pass 'environment DEPLOY_HOST overrides the deployment environment file'

: >"$CF_LOG"
: >"$SSH_LOG"
if env -i HOME="$TEST_DIR/home" PATH="$FAKE_BIN:$PATH" MIRROR_DEPLOY_ENV="$TEST_DIR/complete.env" \
    MIRROR_LISTEN_ADDR=127.0.0.1:65536 FAKE_CF_LOG="$CF_LOG" FAKE_SSH_LOG="$SSH_LOG" \
    "$POSIX_SH" "$SCRIPT_DIR/deploy.sh" --preflight >"$TEST_DIR/invalid-port.log" 2>&1; then
    fail 'out-of-range listen port unexpectedly passed preflight'
fi
contains "$TEST_DIR/invalid-port.log" 'MIRROR_LISTEN_ADDR port must be between 1 and 65535'
[ ! -s "$CF_LOG" ] || fail 'Cloudflare was queried before the invalid listen port was rejected'
[ ! -s "$SSH_LOG" ] || fail 'SSH was invoked before the invalid listen port was rejected'
pass 'invalid listen port fails before Cloudflare or SSH access'

: >"$CF_LOG"
: >"$CF_MUTATIONS"
env PATH="$FAKE_BIN:$PATH" FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" \
    FAKE_CF_MODE=identical CF_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    MIRROR_HOSTNAME=mirror.example.com MIRROR_R2_BUCKET=laputa-mirror \
    MIRROR_CF_TUNNEL=laputa-mirror MIRROR_LISTEN_ADDR=127.0.0.1:3000 \
    "$POSIX_SH" "$SCRIPT_DIR/cloudflare.sh" route "$TEST_DIR/cf-identical" >"$TEST_DIR/cf-identical.log" 2>&1
[ ! -s "$CF_MUTATIONS" ] || fail 'identical Cloudflare state caused a mutation'
contains "$TEST_DIR/cf-identical.log" '=   DNS mirror.example.com'
pass 'identical Cloudflare state performs no mutation'

env PATH="$FAKE_BIN:$PATH" FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" \
    CF_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    MIRROR_HOSTNAME=mirror.example.com MIRROR_R2_BUCKET=laputa-mirror \
    MIRROR_CF_TUNNEL=laputa-mirror MIRROR_LISTEN_ADDR=127.0.0.1:3010 \
    "$POSIX_SH" "$SCRIPT_DIR/cloudflare.sh" preflight "$TEST_DIR/cf-custom-port" >"$TEST_DIR/cf-custom-port.log" 2>&1
contains "$TEST_DIR/cf-custom-port.log" '=   tunnel laputa-mirror'
pass 'preflight accepts the configured custom tunnel listener port'

: >"$CF_MUTATIONS"
if env PATH="$FAKE_BIN:$PATH" FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" \
    FAKE_CF_MODE=conflict CF_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    MIRROR_HOSTNAME=mirror.example.com MIRROR_R2_BUCKET=laputa-mirror \
    MIRROR_CF_TUNNEL=laputa-mirror MIRROR_LISTEN_ADDR=127.0.0.1:3000 \
    "$POSIX_SH" "$SCRIPT_DIR/cloudflare.sh" route "$TEST_DIR/cf-conflict" >"$TEST_DIR/cf-conflict.log" 2>&1; then
    fail 'conflicting Cloudflare DNS record unexpectedly passed'
fi
contains "$TEST_DIR/cf-conflict.log" 'occupied by a non-CNAME DNS record'
[ ! -s "$CF_MUTATIONS" ] || fail 'conflicting Cloudflare state caused a mutation'
pass 'conflicting Cloudflare state fails without mutation'

CF_OBJECT_LIST_COUNT=$TEST_DIR/cf-object-list-count
CF_JOB_POLL_COUNT=$TEST_DIR/cf-job-poll-count
: >"$CF_LOG"
: >"$CF_MUTATIONS"
if env PATH="$FAKE_BIN:$PATH" FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" \
    FAKE_CF_EMPTY_MODE=async FAKE_CF_OBJECT_LIST_COUNT_FILE="$CF_OBJECT_LIST_COUNT" \
    FAKE_CF_JOB_POLL_COUNT_FILE="$CF_JOB_POLL_COUNT" CF_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    MIRROR_HOSTNAME=mirror.example.com MIRROR_R2_BUCKET=laputa-mirror \
    MIRROR_CF_TUNNEL=laputa-mirror MIRROR_LISTEN_ADDR=127.0.0.1:3000 \
    "$POSIX_SH" "$SCRIPT_DIR/cloudflare.sh" empty-bucket "$TEST_DIR/cf-empty" >"$TEST_DIR/cf-empty.log" 2>&1; then
    :
else
    cat "$TEST_DIR/cf-empty.log" >&2
    fail 'R2 bucket emptying failed'
fi
contains "$CF_MUTATIONS" 'r2 objects bulk-delete'
contains "$TEST_DIR/cf-empty.log" 'emptied R2 bucket contents'
assert_equal "$(cat "$CF_JOB_POLL_COUNT")" 2
pass 'R2 bucket emptying polls the asynchronous job and verifies an empty result'

: >"$CF_MUTATIONS"
: >"$CF_OBJECT_LIST_COUNT"
if env PATH="$FAKE_BIN:$PATH" FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" \
    FAKE_CF_EMPTY_MODE=active-job FAKE_CF_OBJECT_LIST_COUNT_FILE="$CF_OBJECT_LIST_COUNT" \
    FAKE_CF_JOB_POLL_COUNT_FILE="$CF_JOB_POLL_COUNT" CF_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    MIRROR_HOSTNAME=mirror.example.com MIRROR_R2_BUCKET=laputa-mirror \
    MIRROR_CF_TUNNEL=laputa-mirror MIRROR_LISTEN_ADDR=127.0.0.1:3000 \
    "$POSIX_SH" "$SCRIPT_DIR/cloudflare.sh" empty-bucket "$TEST_DIR/cf-active" >"$TEST_DIR/cf-active.log" 2>&1; then
    fail 'R2 bucket emptying ignored an active background job'
fi
contains "$TEST_DIR/cf-active.log" 'R2 has active background jobs'
[ ! -s "$CF_MUTATIONS" ] || fail 'R2 bucket was mutated while another background job was active'
pass 'active R2 jobs block a new destructive empty operation'

: >"$CF_MUTATIONS"
: >"$CF_OBJECT_LIST_COUNT"
env PATH="$FAKE_BIN:$PATH" FAKE_CF_LOG="$CF_LOG" FAKE_CF_MUTATIONS="$CF_MUTATIONS" \
    FAKE_CF_EMPTY_MODE=empty FAKE_CF_OBJECT_LIST_COUNT_FILE="$CF_OBJECT_LIST_COUNT" \
    FAKE_CF_JOB_POLL_COUNT_FILE="$CF_JOB_POLL_COUNT" CF_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    MIRROR_HOSTNAME=mirror.example.com MIRROR_R2_BUCKET=laputa-mirror \
    MIRROR_CF_TUNNEL=laputa-mirror MIRROR_LISTEN_ADDR=127.0.0.1:3000 \
    "$POSIX_SH" "$SCRIPT_DIR/cloudflare.sh" empty-bucket "$TEST_DIR/cf-empty-already" >"$TEST_DIR/cf-empty-already.log" 2>&1
contains "$TEST_DIR/cf-empty-already.log" 'R2 bucket already empty'
[ ! -s "$CF_MUTATIONS" ] || fail 'an already-empty R2 bucket caused a mutation'
pass 'an already-empty R2 bucket is left unchanged'

ROOT=$TEST_DIR/host
SYSTEMD_STATE=$TEST_DIR/systemd-state
SYSTEMD_LOG=$TEST_DIR/systemd.log
ATOMIC_LOG=$TEST_DIR/atomic.log
CURL_COUNT=$TEST_DIR/curl-count
mkdir -p "$ROOT/etc/systemd/system" "$ROOT/etc/sysusers.d" "$SYSTEMD_STATE"
: >"$SYSTEMD_LOG"
: >"$ATOMIC_LOG"
: >"$CURL_COUNT"

create_stage() {
    stage_kind=$1
    changed_user=$2
    CREATED_STAGE=$(mktemp -d /tmp/laputa-mirror-test.XXXXXX) || fail 'cannot create deployment fixture'
    case "$stage_kind" in a) STAGE_A=$CREATED_STAGE ;; b) STAGE_B=$CREATED_STAGE ;; bad) STAGE_BAD=$CREATED_STAGE ;; esac
    mkdir -p "$CREATED_STAGE/release/static" "$CREATED_STAGE/host/credentials" "$CREATED_STAGE/host/units" "$CREATED_STAGE/host/sysusers"
    printf 'test mirror binary %s\n' "$stage_kind" >"$CREATED_STAGE/release/laputa-mirror"
    chmod 755 "$CREATED_STAGE/release/laputa-mirror"
    printf '<html>%s</html>\n' "$stage_kind" >"$CREATED_STAGE/release/static/index.html"
    case "$stage_kind" in
        a) CREATED_RELEASE=20261004123456-1 ;;
        b) CREATED_RELEASE=20261004123456-2 ;;
        bad) CREATED_RELEASE=bad/release-id ;;
    esac
    printf '%s\n' "$CREATED_RELEASE" >"$CREATED_STAGE/host/release-id"
    printf 'mirror.example.com\n' >"$CREATED_STAGE/host/hostname"
    printf '127.0.0.1:3000\n' >"$CREATED_STAGE/host/listen-addr"
    printf 'test-access-key-secret\n' >"$CREATED_STAGE/host/credentials/s3-access-key-id"
    printf 'test-s3-secret\n' >"$CREATED_STAGE/host/credentials/s3-secret-access-key"
    printf 'test-tunnel-token-secret\n' >"$CREATED_STAGE/host/credentials/tunnel-token"
    printf 'LISTEN_ADDR=127.0.0.1:3000\nALLOWED_USERS=%s\n' "$changed_user" >"$CREATED_STAGE/host/env"
    cp "$SCRIPT_DIR/laputa-mirror.service" "$CREATED_STAGE/host/units/laputa-mirror.service"
    cp "$SCRIPT_DIR/laputa-cloudflared.service" "$CREATED_STAGE/host/units/laputa-cloudflared.service"
    printf 'u laputa-mirror - "Laputa Package Mirror" /var/lib/laputa-mirror /usr/sbin/nologin\n' >"$CREATED_STAGE/host/sysusers/laputa-mirror.conf"
}

run_host_apply() {
    output=$1
    stage_dir=$2
    failure_mode=$3
    shift 3
    if env PATH="$FAKE_BIN:$PATH" LAPUTA_MIRROR_TEST_ROOT="$ROOT" \
        FAKE_SYSTEMD_STATE="$SYSTEMD_STATE" FAKE_SYSTEMD_LOG="$SYSTEMD_LOG" \
        FAKE_ATOMIC_LOG="$ATOMIC_LOG" FAKE_CURL_COUNT_FILE="$CURL_COUNT" "$@" \
        "$POSIX_SH" "$SCRIPT_DIR/remote-apply.sh" "$stage_dir" >"$output" 2>&1; then
        return 0
    else
        status=$?
        if [ "$failure_mode" = report ]; then cat "$output" >&2; fi
        return "$status"
    fi
}

run_host_runtime() {
    output=$1
    operation=$2
    shift 2
    if env PATH="$FAKE_BIN:$PATH" LAPUTA_MIRROR_TEST_ROOT="$ROOT" \
        FAKE_SYSTEMD_STATE="$SYSTEMD_STATE" FAKE_SYSTEMD_LOG="$SYSTEMD_LOG" \
        FAKE_ATOMIC_LOG="$ATOMIC_LOG" FAKE_CURL_COUNT_FILE="$CURL_COUNT" \
        "$@" \
        "$POSIX_SH" "$SCRIPT_DIR/remote-apply.sh" --mirror-runtime "$operation" 127.0.0.1:3000 >"$output" 2>&1; then
        return 0
    else
        status=$?
        cat "$output" >&2
        return "$status"
    fi
}

run_host_retire() {
    output=$1
    if env PATH="$FAKE_BIN:$PATH" LAPUTA_MIRROR_TEST_ROOT="$ROOT" \
        FAKE_SYSTEMD_STATE="$SYSTEMD_STATE" FAKE_SYSTEMD_LOG="$SYSTEMD_LOG" \
        FAKE_CLOUDFLARED_FRAGMENT=/etc/systemd/system/cloudflared.service \
        "$POSIX_SH" "$SCRIPT_DIR/remote-apply.sh" --retire-old \
        aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee mirror.example.com >"$output" 2>&1; then
        return 0
    else
        status=$?
        cat "$output" >&2
        return "$status"
    fi
}

create_stage a publisher
RELEASE_A=$CREATED_RELEASE
run_host_apply "$TEST_DIR/first-deploy.log" "$STAGE_A" report
assert_equal "$(readlink "$ROOT/opt/laputa-mirror/current")" "releases/$RELEASE_A"
contains "$ATOMIC_LOG" atomic-replace
not_contains "$TEST_DIR/first-deploy.log" test-access-key-secret
not_contains "$TEST_DIR/first-deploy.log" test-s3-secret
not_contains "$TEST_DIR/first-deploy.log" test-tunnel-token-secret
pass 'new release activates through atomic current replacement without printing credentials'

restart_count() {
    grep -c '^restart ' "$SYSTEMD_LOG" || :
}
tunnel_restart_count() {
    grep -c '^restart laputa-cloudflared.service$' "$SYSTEMD_LOG" || :
}
before_restart_count=$(restart_count)
tunnel_restart_count_before=$(tunnel_restart_count)
run_host_apply "$TEST_DIR/second-deploy.log" "$STAGE_A" report
after_restart_count=$(restart_count)
assert_equal "$after_restart_count" "$before_restart_count"
assert_equal "$(tunnel_restart_count)" "$tunnel_restart_count_before"
contains "$TEST_DIR/second-deploy.log" '=   laputa-mirror.service already active'
pass 'identical host deployment leaves healthy services running'

rm -f "$SYSTEMD_STATE/active.laputa-mirror.service" "$SYSTEMD_STATE/enabled.laputa-mirror.service"
rm -f "$SYSTEMD_STATE/active.laputa-cloudflared.service" "$SYSTEMD_STATE/enabled.laputa-cloudflared.service"
before_restart_count=$(restart_count)
run_host_apply "$TEST_DIR/repair-services.log" "$STAGE_A" report
assert_equal "$(restart_count)" "$before_restart_count"
[ -f "$SYSTEMD_STATE/active.laputa-mirror.service" ] || fail 'stopped mirror service was not started'
[ -f "$SYSTEMD_STATE/enabled.laputa-mirror.service" ] || fail 'disabled mirror service was not enabled'
[ -f "$SYSTEMD_STATE/active.laputa-cloudflared.service" ] || fail 'stopped tunnel service was not started'
[ -f "$SYSTEMD_STATE/enabled.laputa-cloudflared.service" ] || fail 'disabled tunnel service was not enabled'
contains "$TEST_DIR/repair-services.log" '+   started laputa-cloudflared.service'
pass 'stopped or disabled services converge back to enabled and active'

create_stage b publisher-updated
printf '\n# changed candidate unit\n' >>"$STAGE_B/host/units/laputa-mirror.service"
printf '0\n' >"$CURL_COUNT"
if run_host_apply "$TEST_DIR/rollback.log" "$STAGE_B" quiet FAKE_CURL_FAIL_FIRST=15; then
    fail 'candidate with a failed health check unexpectedly succeeded'
fi
assert_equal "$(readlink "$ROOT/opt/laputa-mirror/current")" "releases/$RELEASE_A"
assert_equal "$(cat "$ROOT/etc/laputa-mirror/env")" "$(printf 'LISTEN_ADDR=127.0.0.1:3000\nALLOWED_USERS=publisher')"
cmp -s "$SCRIPT_DIR/laputa-mirror.service" "$ROOT/etc/systemd/system/laputa-mirror.service" ||
    fail 'failed deployment did not restore the previous mirror systemd unit'
contains "$TEST_DIR/rollback.log" 'restoring the previous host state'
contains "$TEST_DIR/rollback.log" 'previous release restored and healthy'
pass 'failed health check restores current, application configuration, and service unit'

create_stage bad publisher
printf '0\n' >"$CURL_COUNT"
before_restart_count=$(restart_count)
if run_host_apply "$TEST_DIR/bad-release-id.log" "$STAGE_BAD" quiet; then
    fail 'malformed release ID unexpectedly activated'
fi
after_restart_count=$(restart_count)
assert_equal "$(readlink "$ROOT/opt/laputa-mirror/current")" "releases/$RELEASE_A"
assert_equal "$after_restart_count" "$before_restart_count"
assert_equal "$(cat "$CURL_COUNT")" 0
contains "$TEST_DIR/bad-release-id.log" 'deployment bundle has a malformed release ID'
pass 'malformed release ID fails before activation'

printf '0\n' >"$CURL_COUNT"
if run_host_runtime "$TEST_DIR/runtime-stop-unhealthy.log" stop FAKE_CURL_FAIL_FIRST=1; then
    fail 'unhealthy mirror service was stopped before R2 clearing'
fi
[ -f "$SYSTEMD_STATE/active.laputa-mirror.service" ] || fail 'unhealthy mirror service was stopped'
contains "$TEST_DIR/runtime-stop-unhealthy.log" 'refusing to stop an unhealthy mirror service'
pass 'R2 clearing refuses to stop an unhealthy mirror service'

printf '0\n' >"$CURL_COUNT"
run_host_runtime "$TEST_DIR/runtime-stop.log" stop
[ ! -f "$SYSTEMD_STATE/active.laputa-mirror.service" ] || fail 'mirror runtime stop left the service active'
contains "$TEST_DIR/runtime-stop.log" 'stopped laputa-mirror.service for R2 clearing'
run_host_runtime "$TEST_DIR/runtime-restart.log" restart
[ -f "$SYSTEMD_STATE/active.laputa-mirror.service" ] || fail 'mirror runtime restart did not start the service'
contains "$TEST_DIR/runtime-restart.log" 'restarted with the cleared R2 index'
pass 'mirror runtime can be stopped safely for bucket clearing and restarted with a health check'

mkdir -p "$ROOT/etc/cloudflared"
: >"$ROOT/etc/systemd/system/cloudflared.service"
: >"$SYSTEMD_STATE/active.cloudflared.service"
printf 'tunnel: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nhostname: other.example.com\n' >"$ROOT/etc/cloudflared/config.yml"
: >"$ROOT/etc/cloudflared/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json"
run_host_retire "$TEST_DIR/retire-unrelated-tunnel.log"
[ -f "$ROOT/etc/systemd/system/cloudflared.service" ] || fail 'unrelated cloudflared.service was removed'
[ -f "$ROOT/etc/cloudflared/config.yml" ] || fail 'unrelated tunnel configuration was removed'
[ -f "$SYSTEMD_STATE/active.cloudflared.service" ] || fail 'unrelated cloudflared.service was stopped'
contains "$TEST_DIR/retire-unrelated-tunnel.log" 'no mirror-owned legacy cloudflared.service'
pass 'retiring the mirror preserves a generic tunnel configured for other hostnames'

printf 'tunnel: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nhostname: mirror.example.com\nhostname: other.example.com\n' >"$ROOT/etc/cloudflared/config.yml"
run_host_retire "$TEST_DIR/retire-mixed-tunnel.log"
[ -f "$ROOT/etc/systemd/system/cloudflared.service" ] || fail 'generic tunnel for several hostnames was removed'
[ -f "$ROOT/etc/cloudflared/config.yml" ] || fail 'generic tunnel configuration for several hostnames was removed'
[ -f "$SYSTEMD_STATE/active.cloudflared.service" ] || fail 'generic tunnel for several hostnames was stopped'
pass 'retiring the mirror preserves a generic tunnel shared by several hostnames'

printf 'tunnel: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nhostname: mirror.example.com\n' >"$ROOT/etc/cloudflared/config.yml"
run_host_retire "$TEST_DIR/retire-mirror-tunnel.log"
[ ! -e "$ROOT/etc/systemd/system/cloudflared.service" ] || fail 'mirror-owned cloudflared.service was not removed'
[ ! -e "$ROOT/etc/cloudflared/config.yml" ] || fail 'mirror tunnel configuration was not removed'
[ ! -e "$ROOT/etc/cloudflared/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json" ] || fail 'mirror tunnel credentials were not removed'
[ ! -e "$SYSTEMD_STATE/active.cloudflared.service" ] || fail 'mirror-owned cloudflared.service was not stopped'
pass 'retiring the mirror removes its matching legacy tunnel configuration'

printf 'All mirror deployment tests passed.\n'
