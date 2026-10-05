#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
WORK_DIR=
MIRROR_STOPPED=no

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

say() {
    printf '%s\n' "$*"
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing local command '$1'"
}

load_environment() {
    deploy_host_override_set=${DEPLOY_HOST+x}
    deploy_host_override=${DEPLOY_HOST-}
    if [ -n "${MIRROR_DEPLOY_ENV-}" ]; then
        [ -f "$MIRROR_DEPLOY_ENV" ] || fail "MIRROR_DEPLOY_ENV does not name a file: $MIRROR_DEPLOY_ENV"
        # shellcheck disable=SC1090
        . "$MIRROR_DEPLOY_ENV"
    else
        [ -n "${HOME-}" ] || fail 'HOME is unset; set MIRROR_DEPLOY_ENV explicitly'
        MIRROR_DEPLOY_ENV=$HOME/.config/laputa/mirror-deploy.env
        if [ -f "$MIRROR_DEPLOY_ENV" ]; then
            # shellcheck disable=SC1090
            . "$MIRROR_DEPLOY_ENV"
        fi
    fi

    if [ "$deploy_host_override_set" = x ]; then
        DEPLOY_HOST=$deploy_host_override
    else
        DEPLOY_HOST=${DEPLOY_HOST-ubuntu@oracle}
    fi
    MIRROR_HOSTNAME=${MIRROR_HOSTNAME-laputa.17166969.xyz}
    MIRROR_R2_BUCKET=${MIRROR_R2_BUCKET-laputa-mirror}
    MIRROR_CF_TUNNEL=${MIRROR_CF_TUNNEL-laputa-mirror}
    MIRROR_LISTEN_ADDR=${MIRROR_LISTEN_ADDR-127.0.0.1:3000}
    MIRROR_DEPLOY_ENV=${MIRROR_DEPLOY_ENV-}
    export CLOUDFLARE_API_TOKEN S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
    export S3_ACCESS_KEY_ID_FILE S3_SECRET_ACCESS_KEY_FILE MIRROR_ALLOWED_USERS
    export CF_ACCOUNT_ID MIRROR_HOSTNAME MIRROR_R2_BUCKET MIRROR_CF_TUNNEL MIRROR_LISTEN_ADDR
}

validate_config() {
    case "$DEPLOY_HOST" in
        ''|*[!A-Za-z0-9_.@-]*|*@*@*) fail 'DEPLOY_HOST must be an SSH host or user@host from ~/.ssh/config' ;;
    esac
    case "$MIRROR_HOSTNAME" in
        ''|.*|*.|*..*|*[!A-Za-z0-9.-]*) fail 'MIRROR_HOSTNAME must be a DNS hostname' ;;
    esac
    case "$MIRROR_R2_BUCKET" in
        ''|*[!a-z0-9-]*) fail 'MIRROR_R2_BUCKET must use lowercase letters, digits, and hyphens' ;;
    esac
    case "$MIRROR_CF_TUNNEL" in
        ''|*[!A-Za-z0-9_-]*) fail 'MIRROR_CF_TUNNEL must use letters, digits, hyphens, and underscores' ;;
    esac
    case "$MIRROR_LISTEN_ADDR" in
        127.0.0.1:*) MIRROR_PORT=${MIRROR_LISTEN_ADDR#127.0.0.1:} ;;
        *) fail 'MIRROR_LISTEN_ADDR must bind to 127.0.0.1' ;;
    esac
    case "$MIRROR_PORT" in
        ''|*[!0-9]*) fail 'MIRROR_LISTEN_ADDR must end in a numeric port' ;;
    esac
    [ "${#MIRROR_PORT}" -le 5 ] || fail 'MIRROR_LISTEN_ADDR port must be between 1 and 65535'
    if [ "$MIRROR_PORT" -lt 1 ] || [ "$MIRROR_PORT" -gt 65535 ]; then
        fail 'MIRROR_LISTEN_ADDR port must be between 1 and 65535'
    fi
    case "${CF_ACCOUNT_ID-}" in
        '') ;;
        *[!0-9a-f]* ) fail 'CF_ACCOUNT_ID must be a lowercase Cloudflare account ID' ;;
    esac
    if [ -n "${CF_ACCOUNT_ID-}" ] && [ "${#CF_ACCOUNT_ID}" -ne 32 ]; then
        fail 'CF_ACCOUNT_ID must contain 32 hexadecimal characters'
    fi
    if [ -n "${JWT_JWKS_URL-}" ]; then
        [ -n "${JWT_ISSUER-}" ] || fail 'JWT_ISSUER is required when JWT_JWKS_URL is set'
        [ -n "${JWT_AUDIENCE-}" ] || fail 'JWT_AUDIENCE is required when JWT_JWKS_URL is set'
        [ -n "${JWT_SUBJECT_PATTERN-}" ] || fail 'JWT_SUBJECT_PATTERN is required when JWT_JWKS_URL is set'
    else
        [ -z "${JWT_ISSUER-}" ] || fail 'JWT_JWKS_URL is required when JWT_ISSUER is set'
        [ -z "${JWT_AUDIENCE-}" ] || fail 'JWT_JWKS_URL is required when JWT_AUDIENCE is set'
        [ -z "${JWT_SUBJECT_PATTERN-}" ] || fail 'JWT_JWKS_URL is required when JWT_SUBJECT_PATTERN is set'
    fi
}

resolve_account() {
    local_accounts=$1
    cf accounts list >"$local_accounts" || fail 'Cloudflare authentication failed; run cf auth login or configure CLOUDFLARE_API_TOKEN'
    if [ -z "${CF_ACCOUNT_ID-}" ]; then
        count=$(jq 'length' "$local_accounts") || fail 'cf accounts list did not return JSON'
        [ "$count" -eq 1 ] || fail 'set CF_ACCOUNT_ID because cf authentication can access multiple accounts'
        CF_ACCOUNT_ID=$(jq -er '.[0].id' "$local_accounts") || fail 'cf accounts list has no account ID'
    fi
    case "$CF_ACCOUNT_ID" in *[!0-9a-f]*) fail 'cf accounts list returned an invalid account ID' ;; esac
    [ "${#CF_ACCOUNT_ID}" -eq 32 ] || fail 'Cloudflare account IDs must contain 32 hexadecimal characters'
    jq -e --arg account "$CF_ACCOUNT_ID" '[.[] | select(.id == $account)] | length == 1' "$local_accounts" >/dev/null ||
        fail 'CF_ACCOUNT_ID is not available to the authenticated cf profile'
    export CF_ACCOUNT_ID CLOUDFLARE_ACCOUNT_ID
    CLOUDFLARE_ACCOUNT_ID=$CF_ACCOUNT_ID
}

secret_source_is_usable() {
    direct_name=$1
    direct_set=$2
    direct_value=$3
    file_name=$4
    file_value=$5
    if [ "$direct_set" = x ]; then
        [ -n "$direct_value" ] || fail "$direct_name is set but empty"
    elif [ -n "$file_value" ]; then
        [ -f "$file_value" ] && [ -r "$file_value" ] && [ -s "$file_value" ] ||
            fail "$file_name must name a readable, non-empty file"
    else
        fail "set $direct_name or $file_name in the deployment environment"
    fi
}

check_local() {
    need_command ssh
    need_command tar
    need_command jq
    need_command curl
    need_command cf
    need_command docker
    need_command deno
    need_command node
    need_command date
    docker buildx version >/dev/null 2>&1 || fail 'Docker Buildx is required for mirror-build-x86_64-musl'
    [ -f "$REPO_ROOT/mirror/Dockerfile" ] || fail 'mirror/Dockerfile is missing'
    [ -f "$REPO_ROOT/mirror/package.json" ] || fail 'mirror/package.json is missing'
    [ -f "$REPO_ROOT/mirror/pnpm-lock.yaml" ] || fail 'mirror/pnpm-lock.yaml is missing'
    [ -d "$REPO_ROOT/mirror/static" ] || fail 'mirror/static is missing'
    secret_source_is_usable S3_ACCESS_KEY_ID "${S3_ACCESS_KEY_ID+x}" "${S3_ACCESS_KEY_ID-}" S3_ACCESS_KEY_ID_FILE "${S3_ACCESS_KEY_ID_FILE-}"
    secret_source_is_usable S3_SECRET_ACCESS_KEY "${S3_SECRET_ACCESS_KEY+x}" "${S3_SECRET_ACCESS_KEY-}" S3_SECRET_ACCESS_KEY_FILE "${S3_SECRET_ACCESS_KEY_FILE-}"
    [ -n "${MIRROR_ALLOWED_USERS-}" ] || fail 'set MIRROR_ALLOWED_USERS to one or more publisher usernames'
    case "$MIRROR_ALLOWED_USERS" in
        *[!A-Za-z0-9_.@,-]*) fail 'MIRROR_ALLOWED_USERS contains unsupported characters' ;;
    esac
    say 'ok  local build and deployment tools'
    say 'ok  required mirror credentials are configured'
}

check_remote() {
    ssh -o BatchMode=yes "$DEPLOY_HOST" /bin/sh -s <<'REMOTE_PREFLIGHT' || fail "SSH or remote preflight failed for $DEPLOY_HOST"
set -eu
fail() { printf 'remote preflight: %s\n' "$*" >&2; exit 1; }
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail 'non-root SSH user needs sudo'
    sudo -n true || fail 'non-root SSH user needs passwordless sudo (sudo -n true failed)'
fi
[ "$(uname -s)" = Linux ] || fail 'deployment host must run Linux'
case "$(uname -m)" in x86_64|amd64) ;; *) fail 'deployment host must use x86_64';; esac
for command_name in systemctl systemd-sysusers systemd-analyze tar install cmp readlink curl flock find sort grep mv ln; do
    command -v "$command_name" >/dev/null 2>&1 || fail "missing remote prerequisite: $command_name"
done
[ -x /usr/bin/cloudflared ] || fail 'install cloudflared at /usr/bin/cloudflared'
systemd_version=$(systemctl --version | { read -r _ version _; printf '%s' "$version"; })
case "$systemd_version" in ''|*[!0-9]*) fail 'could not determine systemd version';; esac
[ "$systemd_version" -ge 247 ] || fail 'systemd 247 or newer is required for LoadCredential and %d'
/usr/bin/cloudflared tunnel run --help 2>&1 | grep -- '--token-file' >/dev/null ||
    fail 'installed cloudflared does not support tunnel run --token-file'
printf 'ok  remote Linux, systemd %s, and cloudflared\n' "$systemd_version"
REMOTE_PREFLIGHT
}

run_preflight() {
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/laputa-mirror-preflight.XXXXXX") || fail 'cannot create local preflight directory'
    trap 'rm -rf "$tmp"' 0 HUP INT TERM
    check_local
    resolve_account "$tmp/accounts.json"
    check_remote
    "$SCRIPT_DIR/cloudflare.sh" preflight "$tmp/cloudflare"
    say "ok  SSH $DEPLOY_HOST"
    say 'ok  Cloudflare authentication and resource state'
}

copy_secret() {
    direct_set=$1
    direct_value=$2
    file_value=$3
    destination=$4
    if [ "$direct_set" = x ]; then
        printf '%s' "$direct_value" >"$destination"
    else
        cat "$file_value" >"$destination"
    fi
    chmod 600 "$destination"
}

emit_config() {
    config_path=$1
    CONFIG_PATH=$config_path
    s3_endpoint=https://$CF_ACCOUNT_ID.r2.cloudflarestorage.com
    {
        printf 'LISTEN_ADDR=%s\n' "$MIRROR_LISTEN_ADDR"
        printf 'S3_ENDPOINT=%s\n' "$s3_endpoint"
        printf 'S3_BUCKET=%s\n' "$MIRROR_R2_BUCKET"
        printf 'S3_REGION=auto\n'
        printf 'DB_PATH=/var/lib/laputa-mirror/auth.db\n'
        printf 'UPLOAD_DIR=/var/lib/laputa-mirror/uploads\n'
        printf 'ALLOWED_USERS=%s\n' "$MIRROR_ALLOWED_USERS"
        printf 'RP_ID=%s\n' "$MIRROR_HOSTNAME"
        printf 'RP_ORIGIN=https://%s\n' "$MIRROR_HOSTNAME"
    } >"$config_path"
    append_optional JWT_JWKS_URL "${JWT_JWKS_URL-}"
    append_optional JWT_ISSUER "${JWT_ISSUER-}"
    append_optional JWT_AUDIENCE "${JWT_AUDIENCE-}"
    append_optional JWT_SUBJECT_PATTERN "${JWT_SUBJECT_PATTERN-}"
    append_optional R2_PUBLIC_URL "${R2_PUBLIC_URL-}"
}

append_optional() {
    optional_name=$1
    optional_value=$2
    [ -n "$optional_value" ] || return 0
    case "$optional_name:$optional_value" in
        JWT_JWKS_URL:https://*|JWT_ISSUER:https://*|R2_PUBLIC_URL:https://*)
            case "$optional_value" in *[!A-Za-z0-9./:_@%+-]*) fail "$optional_name contains unsupported characters" ;; esac
            ;;
        JWT_AUDIENCE:*[!A-Za-z0-9,_.:-]*) fail 'JWT_AUDIENCE contains unsupported characters' ;;
        JWT_AUDIENCE:*) ;;
        JWT_SUBJECT_PATTERN:*[!A-Za-z0-9_:*./-]*) fail 'JWT_SUBJECT_PATTERN contains unsupported characters' ;;
        JWT_SUBJECT_PATTERN:*) ;;
        *) fail "$optional_name has an unsupported value" ;;
    esac
    printf '%s=%s\n' "$optional_name" "$optional_value" >>"$CONFIG_PATH"
}

make_release() {
    release_dir=$1
    binary="$REPO_ROOT/mirror/target/docker-output/laputa-mirror"
    [ -f "$binary" ] && [ -x "$binary" ] || fail 'missing x86_64 release binary; run make mirror-build-x86_64-musl'
    [ -d "$REPO_ROOT/mirror/static" ] || fail 'missing frontend output; run make mirror-frontend'
    mkdir -p "$release_dir/static"
    install -m 755 "$binary" "$release_dir/laputa-mirror"
    cp -R "$REPO_ROOT/mirror/static/." "$release_dir/static/"
    RELEASE_ID=$(date -u +%Y%m%d%H%M%S)-$$ || fail 'cannot create a release ID'
    export RELEASE_ID
}

remote_release_validity() {
    release_id=$1
    result=$2
    ssh -o BatchMode=yes "$DEPLOY_HOST" \
        "if [ \"\$(id -u)\" -eq 0 ]; then exec /bin/sh -s -- --check-release $release_id; else exec sudo -n /bin/sh -s -- --check-release $release_id; fi" \
        <"$SCRIPT_DIR/remote-apply.sh" >"$result" ||
        fail 'could not inspect the installed release on the deployment host'
}

create_bundle() {
    bundle=$1
    include_release=$2
    mkdir -p "$bundle/host/credentials" "$bundle/host/units" "$bundle/host/sysusers"
    [ "$include_release" != yes ] || cp -R "$WORK_DIR/release" "$bundle/release"
    emit_config "$bundle/host/env"
    copy_secret "${S3_ACCESS_KEY_ID+x}" "${S3_ACCESS_KEY_ID-}" "${S3_ACCESS_KEY_ID_FILE-}" "$bundle/host/credentials/s3-access-key-id"
    copy_secret "${S3_SECRET_ACCESS_KEY+x}" "${S3_SECRET_ACCESS_KEY-}" "${S3_SECRET_ACCESS_KEY_FILE-}" "$bundle/host/credentials/s3-secret-access-key"
    install -m 600 "$WORK_DIR/tunnel-token" "$bundle/host/credentials/tunnel-token"
    install -m 644 "$SCRIPT_DIR/laputa-mirror.service" "$bundle/host/units/laputa-mirror.service"
    install -m 644 "$SCRIPT_DIR/laputa-cloudflared.service" "$bundle/host/units/laputa-cloudflared.service"
    install -m 644 "$SCRIPT_DIR/laputa-mirror.sysusers" "$bundle/host/sysusers/laputa-mirror.conf"
    install -m 755 "$SCRIPT_DIR/remote-apply.sh" "$bundle/remote-apply.sh"
    printf '%s\n' "$RELEASE_ID" >"$bundle/host/release-id"
    printf '%s\n' "$MIRROR_HOSTNAME" >"$bundle/host/hostname"
    printf '%s\n' "$MIRROR_LISTEN_ADDR" >"$bundle/host/listen-addr"
}

remote_current_release() {
    destination=$1
    ssh -o BatchMode=yes "$DEPLOY_HOST" \
        'if [ "$(id -u)" -eq 0 ]; then exec /bin/sh -s -- --current-release; else exec sudo -n /bin/sh -s -- --current-release; fi' \
        <"$SCRIPT_DIR/remote-apply.sh" >"$destination" || fail 'could not read the current host release'
}

remote_retire_old() {
    old_id=$1
    hostname=$2
    case "$old_id" in ????????-????-????-????-????????????) ;; *) fail 'invalid legacy tunnel ID';; esac
    ssh -o BatchMode=yes "$DEPLOY_HOST" \
        "if [ \"\$(id -u)\" -eq 0 ]; then exec /bin/sh -s -- --retire-old $old_id $hostname; else exec sudo -n /bin/sh -s -- --retire-old $old_id $hostname; fi" \
        <"$SCRIPT_DIR/remote-apply.sh"
}

remote_mirror_runtime() {
    operation=$1
    case "$operation" in stop|restart) ;; *) fail 'invalid mirror runtime operation' ;; esac
    ssh -o BatchMode=yes "$DEPLOY_HOST" \
        "if [ \"\$(id -u)\" -eq 0 ]; then exec /bin/sh -s -- --mirror-runtime $operation $MIRROR_LISTEN_ADDR; else exec sudo -n /bin/sh -s -- --mirror-runtime $operation $MIRROR_LISTEN_ADDR; fi" \
        <"$SCRIPT_DIR/remote-apply.sh" || fail "could not $operation laputa-mirror.service on $DEPLOY_HOST"
}

cleanup_deploy() {
    cleanup_status=$?
    trap - 0 HUP INT TERM
    if [ "$MIRROR_STOPPED" = yes ]; then
        if "$SCRIPT_DIR/cloudflare.sh" wait-empty "$WORK_DIR/cloudflare" && remote_mirror_runtime restart; then
            MIRROR_STOPPED=no
        else
            printf 'error: the R2 clear may still be running; laputa-mirror.service remains stopped to prevent writes\n' >&2
            if [ "$cleanup_status" -eq 0 ]; then cleanup_status=1; fi
        fi
    fi
    if [ -n "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
    exit "$cleanup_status"
}

remote_gc() {
    current_id=$1
    previous_id=$2
    valid_id() {
        case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
        [ "${#1}" -le 80 ]
    }
    valid_id "$current_id" || fail 'invalid current release ID for release cleanup'
    [ -z "$previous_id" ] || valid_id "$previous_id" || fail 'invalid previous release ID for release cleanup'
    ssh -o BatchMode=yes "$DEPLOY_HOST" \
        "if [ \"\$(id -u)\" -eq 0 ]; then exec /bin/sh -s -- --gc $current_id '$previous_id'; else exec sudo -n /bin/sh -s -- --gc $current_id '$previous_id'; fi" \
        <"$SCRIPT_DIR/remote-apply.sh"
}

check_public_health() {
    attempt=0
    public_url=https://$MIRROR_HOSTNAME/health
    while [ "$attempt" -lt 20 ]; do
        if curl -fsS --max-time 5 --output /dev/null "$public_url"; then
            say "ok  $public_url"
            return
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    fail "$public_url did not become healthy; check laputa-cloudflared.service and Cloudflare tunnel ingress"
}

deploy() {
    fresh_start=$1
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/laputa-mirror-deploy.XXXXXX") || fail 'cannot create local deploy directory'
    WORK_DIR=$tmp
    export WORK_DIR
    MIRROR_STOPPED=no
    trap cleanup_deploy 0
    trap 'exit 1' HUP INT TERM
    mkdir -p "$WORK_DIR/release"
    make_release "$WORK_DIR/release"
    say "release $RELEASE_ID"

    remote_current_release "$WORK_DIR/previous-release"
    PREVIOUS_ID=$(cat "$WORK_DIR/previous-release")
    mkdir -p "$WORK_DIR/bundle"
    validity="$WORK_DIR/release-validity"
    remote_release_validity "$RELEASE_ID" "$validity"
    if [ "$(cat "$validity")" = valid ]; then
        say "=   release $RELEASE_ID"
        include_release=no
    else
        say "+   release $RELEASE_ID"
        include_release=yes
    fi
    "$SCRIPT_DIR/cloudflare.sh" prepare "$WORK_DIR/cloudflare" "$WORK_DIR/tunnel-token"
    create_bundle "$WORK_DIR/bundle" "$include_release"
    # Prevent macOS libarchive from adding AppleDouble files for extended attributes.
    COPYFILE_DISABLE=1 tar -cf "$WORK_DIR/bundle.tar" -C "$WORK_DIR/bundle" .
    chmod 600 "$WORK_DIR/bundle.tar"
    ssh -o BatchMode=yes "$DEPLOY_HOST" \
        'set -eu; umask 077; stage=$(mktemp -d /tmp/laputa-mirror-upload.XXXXXX); case "$stage" in /tmp/laputa-mirror-upload.*) ;; *) exit 1 ;; esac; trap '\''rm -rf "$stage"'\'' 0 HUP INT TERM; tar -xf - -C "$stage"; if [ "$(id -u)" -eq 0 ]; then /bin/sh "$stage/remote-apply.sh" "$stage"; else sudo -n /bin/sh "$stage/remote-apply.sh" "$stage"; fi' \
        <"$WORK_DIR/bundle.tar"
    "$SCRIPT_DIR/cloudflare.sh" verify "$WORK_DIR/cloudflare"
    "$SCRIPT_DIR/cloudflare.sh" route "$WORK_DIR/cloudflare"
    check_public_health
    if [ "$fresh_start" = yes ]; then
        remote_mirror_runtime stop
        MIRROR_STOPPED=yes
        "$SCRIPT_DIR/cloudflare.sh" empty-bucket "$WORK_DIR/cloudflare"
        remote_mirror_runtime restart
        MIRROR_STOPPED=no
        check_public_health
    fi
    legacy_id=$(cat "$WORK_DIR/cloudflare/legacy-tunnel-id")
    if [ -n "$legacy_id" ]; then
        remote_retire_old "$legacy_id" "$MIRROR_HOSTNAME"
        "$SCRIPT_DIR/cloudflare.sh" retire "$WORK_DIR/cloudflare"
    fi
    remote_gc "$RELEASE_ID" "$PREVIOUS_ID"
}

main() {
    load_environment
    validate_config
    case "${1-}" in
        --preflight)
            [ "$#" -eq 1 ] || fail 'usage: deploy.sh --preflight'
            run_preflight
            ;;
        '')
            run_preflight
            deploy no
            ;;
        --fresh-start)
            [ "$#" -eq 1 ] || fail 'usage: deploy.sh --fresh-start'
            run_preflight
            deploy yes
            ;;
        *) fail 'usage: deploy.sh [--preflight|--fresh-start]' ;;
    esac
}

main "$@"
