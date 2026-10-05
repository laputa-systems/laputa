#!/bin/sh
set -eu
umask 077

fail() {
    printf 'host deploy: %s\n' "$*" >&2
    exit 1
}

say() {
    printf '%s\n' "$*"
}

TEST_ROOT=${LAPUTA_MIRROR_TEST_ROOT-}

managed_path() {
    if [ -n "$TEST_ROOT" ]; then
        printf '%s%s' "$TEST_ROOT" "$1"
    else
        printf '%s' "$1"
    fi
}

valid_release_id() {
    case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "${#1}" -le 80 ]
}

reject_links() {
    if find "$1" -type l -print | grep . >/dev/null; then
        fail "unexpected symlink under $1"
    fi
}

verify_release() {
    verify_dir=$1
    verify_id=$2
    valid_release_id "$verify_id" || fail 'malformed release ID'
    [ -d "$verify_dir" ] && [ ! -L "$verify_dir" ] || fail "release directory is missing or a symlink: $verify_id"
    [ -f "$verify_dir/laputa-mirror" ] && [ -x "$verify_dir/laputa-mirror" ] && [ ! -L "$verify_dir/laputa-mirror" ] || fail 'release has no executable laputa-mirror binary'
    [ -d "$verify_dir/static" ] && [ ! -L "$verify_dir/static" ] || fail 'release has no regular static directory'
    reject_links "$verify_dir"
}

release_directory() {
    install_root=$(managed_path /opt/laputa-mirror)
    printf '%s/releases/%s' "$install_root" "$1"
}

read_current_id() {
    current_path=$(managed_path /opt/laputa-mirror/current)
    if [ ! -e "$current_path" ] && [ ! -L "$current_path" ]; then
        printf '\n'
        return
    fi
    [ -L "$current_path" ] || fail '/opt/laputa-mirror/current must be a symlink'
    current_target=$(readlink "$current_path") || fail 'could not read the current release symlink'
    case "$current_target" in releases/*) current_id=${current_target#releases/} ;; *) fail 'current points outside the Laputa release directory' ;; esac
    valid_release_id "$current_id" || fail 'current points to a malformed release ID'
    verify_release "$(release_directory "$current_id")" "$current_id"
    printf '%s\n' "$current_id"
}

check_installed_release() {
    check_id=$1
    check_dir=$(release_directory "$check_id")
    if [ ! -e "$check_dir" ] && [ ! -L "$check_dir" ]; then
        printf 'missing\n'
        return 0
    fi
    verify_release "$check_dir" "$check_id"
    printf 'valid\n'
}

check_root() {
    if [ -n "$TEST_ROOT" ]; then
        [ -d "$TEST_ROOT" ] || fail 'LAPUTA_MIRROR_TEST_ROOT must name an existing directory'
    else
        [ "$(id -u)" -eq 0 ] || fail 'remote apply must run as root or through passwordless sudo'
    fi
}

check_release_probe() {
    [ "$#" -eq 2 ] || fail 'usage: remote-apply.sh --check-release RELEASE_ID'
    check_root
    check_installed_release "$2"
}

check_current_probe() {
    [ "$#" -eq 1 ] || fail 'usage: remote-apply.sh --current-release'
    check_root
    read_current_id
}

remote_mirror_runtime() {
    [ "$#" -eq 3 ] || fail 'usage: remote-apply.sh --mirror-runtime stop|restart LISTEN_ADDR'
    operation=$2
    listen_addr=$3
    case "$operation" in stop|restart) ;; *) fail 'mirror runtime operation must be stop or restart' ;; esac
    case "$listen_addr" in
        127.0.0.1:*) listen_port=${listen_addr#127.0.0.1:} ;;
        *) fail 'mirror listen address must bind to 127.0.0.1' ;;
    esac
    case "$listen_port" in ''|*[!0-9]*) fail 'mirror listen address must end in a numeric port' ;; esac
    check_root
    acquire_lock
    current_id=$(read_current_id)
    [ -n "$current_id" ] || fail 'no current mirror release is installed'
    LOCAL_HEALTH_URL=http://$listen_addr/health
    export LOCAL_HEALTH_URL

    if [ "$operation" = stop ]; then
        if ! systemctl is-active laputa-mirror.service >/dev/null 2>&1; then
            say '=   laputa-mirror.service already stopped'
            return 0
        fi
        curl -fsS --max-time 2 "$LOCAL_HEALTH_URL" >/dev/null 2>&1 ||
            fail 'refusing to stop an unhealthy mirror service before clearing R2'
        systemctl stop laputa-mirror.service || fail 'could not stop laputa-mirror.service before clearing R2'
        if systemctl is-active laputa-mirror.service >/dev/null 2>&1; then
            fail 'laputa-mirror.service remained active after stop'
        fi
        say '->  stopped laputa-mirror.service for R2 clearing'
        return 0
    fi

    systemctl restart laputa-mirror.service || fail 'could not restart laputa-mirror.service after clearing R2'
    wait_local_health || { show_mirror_journal; fail "$LOCAL_HEALTH_URL did not become healthy after restart"; }
    systemctl is-active laputa-mirror.service >/dev/null 2>&1 || fail 'laputa-mirror.service is not active after restart'
    say 'ok  laputa-mirror.service restarted with the cleared R2 index'
}

remote_retire_legacy() {
    [ "$#" -eq 3 ] || fail 'usage: remote-apply.sh --retire-old TUNNEL_ID HOSTNAME'
    check_root
    acquire_lock
    case "$2" in ????????-????-????-????-????????????) ;; *) fail 'invalid old tunnel ID' ;; esac
    case "$2" in *[!0-9a-f-]*) fail 'invalid old tunnel ID' ;; esac
    case "$3" in ''|*[!A-Za-z0-9.-]*|*..*) fail 'invalid old mirror hostname' ;; esac
    old_config=$(managed_path /etc/cloudflared/config.yml)
    old_credentials=$(managed_path "/etc/cloudflared/$2.json")
    owns_mirror_config=no
    if [ -f "$old_config" ] && grep -F "$2" "$old_config" >/dev/null && grep -F "$3" "$old_config" >/dev/null; then
        hostname_count=$(grep -c 'hostname:' "$old_config" || :)
        if [ "$hostname_count" = 1 ]; then owns_mirror_config=yes; fi
    fi
    unit_path=$(managed_path /etc/systemd/system/cloudflared.service)
    fragment=$(systemctl show cloudflared.service -p FragmentPath --value 2>/dev/null || :)
    if [ "$fragment" = /etc/systemd/system/cloudflared.service ] && [ "$owns_mirror_config" = yes ]; then
        systemctl disable --now cloudflared.service >/dev/null 2>&1 || fail 'could not stop and disable the legacy cloudflared.service'
        rm -f "$unit_path"
        systemctl daemon-reload || fail 'systemd reload failed after removing legacy cloudflared.service'
        say '=   retired old cloudflared.service'
    else
        say '=   no mirror-owned legacy cloudflared.service'
    fi
    if [ "$owns_mirror_config" = yes ]; then
        rm -f "$old_config"
        [ ! -f "$old_credentials" ] || rm -f "$old_credentials"
        say '~   removed legacy local tunnel configuration'
    fi
    if command -v dpkg-query >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
        package_status=$(dpkg-query -W -f='${db:Status-Status}' laputa-mirror 2>/dev/null || :)
        if [ "$package_status" = installed ]; then
            dpkg --remove laputa-mirror || fail 'could not remove the legacy laputa-mirror Debian package'
            say '~   removed legacy laputa-mirror Debian package'
        fi
    fi
}

capture_file() {
    capture_dest=$1
    capture_name=$2
    if [ -L "$capture_dest" ]; then
        fail "managed host file is a symlink: $capture_dest"
    fi
    if [ -f "$capture_dest" ]; then
        cp -p "$capture_dest" "$BACKUP_DIR/$capture_name"
        printf '%s\n' "$capture_name" >>"$BACKUP_DIR/existing-files"
    elif [ -e "$capture_dest" ]; then
        fail "managed host path is not a regular file: $capture_dest"
    fi
}

restore_file() {
    restore_dest=$1
    restore_name=$2
    if grep -Fx "$restore_name" "$BACKUP_DIR/existing-files" >/dev/null; then
        restore_tmp=$restore_dest.restore.$$
        cp -p "$BACKUP_DIR/$restore_name" "$restore_tmp"
        mv -f "$restore_tmp" "$restore_dest"
    else
        rm -f "$restore_dest"
    fi
}

rollback_transaction() {
    say 'error: mirror health check failed; restoring the previous host state' >&2
    restore_file "$MIRROR_UNIT" mirror-unit
    restore_file "$CLOUDFLARED_UNIT" cloudflared-unit
    restore_file "$SYSUSERS_FILE" sysusers-file
    restore_file "$ENV_FILE" env-file
    restore_file "$S3_KEY_FILE" s3-key
    restore_file "$S3_SECRET_FILE" s3-secret
    restore_file "$TUNNEL_TOKEN_FILE" tunnel-token
    if [ -n "$PREVIOUS_ID" ]; then
        link_tmp=$CURRENT.new.rollback.$$
        ln -s "releases/$PREVIOUS_ID" "$link_tmp"
        mv -Tf "$link_tmp" "$CURRENT"
    else
        rm -f "$CURRENT"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || :
    if [ -n "$PREVIOUS_ID" ]; then
        if [ "$PREVIOUS_APP_ENABLED" = yes ]; then
            systemctl enable laputa-mirror.service >/dev/null 2>&1 || :
        else
            systemctl disable laputa-mirror.service >/dev/null 2>&1 || :
        fi
        systemctl restart laputa-mirror.service >/dev/null 2>&1 || :
        if wait_local_health; then
            say 'ok  previous release restored and healthy'
        else
            say 'error: previous release did not become healthy; inspect journalctl -u laputa-mirror.service -n 50 --no-pager' >&2
        fi
    else
        systemctl stop laputa-mirror.service >/dev/null 2>&1 || :
        systemctl disable laputa-mirror.service >/dev/null 2>&1 || :
        say 'error: first deployment failed; laputa-mirror.service is stopped and current is absent' >&2
    fi
}

on_exit() {
    exit_status=$?
    trap - 0 HUP INT TERM
    if [ "$TRANSACTION_STARTED" = yes ] && [ "$APP_COMMITTED" != yes ] && [ "$exit_status" -ne 0 ]; then
        rollback_transaction || :
    fi
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        case "$BACKUP_DIR" in /tmp/laputa-mirror-backup.*) rm -rf "$BACKUP_DIR" ;; esac
    fi
    if [ -n "$ROOT_STAGE" ] && [ -d "$ROOT_STAGE" ]; then
        case "$ROOT_STAGE" in /tmp/laputa-mirror-root.*) rm -rf "$ROOT_STAGE" ;; esac
    fi
    exit "$exit_status"
}

install_if_changed() {
    source_file=$1
    destination_file=$2
    mode=$3
    change_kind=$4
    if [ -f "$destination_file" ]; then
        if cmp -s "$source_file" "$destination_file"; then
            say "=   $change_kind"
            INSTALL_CHANGED=no
            return 0
        else
            comparison_status=$?
            [ "$comparison_status" -eq 1 ] || fail "could not compare managed file: $destination_file"
        fi
    fi
    temporary_file=$destination_file.new.$$
    install -m "$mode" "$source_file" "$temporary_file" || fail "could not stage managed file: $destination_file"
    mv -f "$temporary_file" "$destination_file" || fail "could not replace managed file: $destination_file"
    say "~   $change_kind"
    INSTALL_CHANGED=yes
}

ensure_directory() {
    dir_path=$1
    dir_mode=$2
    dir_owner=$3
    dir_group=$4
    if [ -L "$dir_path" ]; then fail "managed directory is a symlink: $dir_path"; fi
    if [ -n "$TEST_ROOT" ]; then
        install -d -m "$dir_mode" "$dir_path"
    else
        install -d -o "$dir_owner" -g "$dir_group" -m "$dir_mode" "$dir_path"
    fi
}

set_release_ownership() {
    release_path=$1
    reject_links "$release_path"
    if [ -z "$TEST_ROOT" ]; then
        chown -R root:root "$release_path"
    fi
    find "$release_path" -type d -exec chmod 755 {} \;
    find "$release_path" -type f -exec chmod 644 {} \;
    chmod 755 "$release_path/laputa-mirror"
    chmod 755 "$release_path"
}

install_release() {
    source_release=$1
    release_id=$2
    releases_path=$(managed_path /opt/laputa-mirror/releases)
    final_path="$releases_path/$release_id"
    if [ -e "$final_path" ] || [ -L "$final_path" ]; then
        verify_release "$final_path" "$release_id"
        say "=   release $release_id"
        return
    fi
    [ -d "$source_release" ] || fail 'deployment bundle does not contain its new release'
    verify_release "$source_release" "$release_id"
    build_path="$releases_path/.install-$release_id-$$"
    [ ! -e "$build_path" ] && [ ! -L "$build_path" ] || fail 'release installation staging path already exists'
    mkdir "$build_path"
    cp -R "$source_release/." "$build_path/"
    verify_release "$build_path" "$release_id"
    set_release_ownership "$build_path"
    mv "$build_path" "$final_path"
    say "+   release $release_id"
}

activate_release() {
    release_id=$1
    CURRENT=$(managed_path /opt/laputa-mirror/current)
    desired_target=releases/$release_id
    if [ -L "$CURRENT" ] && [ "$(readlink "$CURRENT")" = "$desired_target" ]; then
        say "=   current $release_id"
        ACTIVATED=no
        return 0
    fi
    if [ -e "$CURRENT" ] && [ ! -L "$CURRENT" ]; then
        fail '/opt/laputa-mirror/current exists and is not a symlink'
    fi
    link_tmp=$CURRENT.new.$$
    [ ! -e "$link_tmp" ] && [ ! -L "$link_tmp" ] || fail 'current symlink staging path already exists'
    ln -s "$desired_target" "$link_tmp" || fail 'could not stage the current release symlink'
    mv -Tf "$link_tmp" "$CURRENT" || fail 'could not atomically activate the mirror release'
    say "->  activated $release_id"
    ACTIVATED=yes
}

wait_local_health() {
    attempt=0
    while [ "$attempt" -lt 15 ]; do
        if curl -fsS --max-time 2 "$LOCAL_HEALTH_URL" >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

show_mirror_journal() {
    journalctl -u laputa-mirror.service -n 50 --no-pager >&2 || :
}

apply_bundle() {
    STAGE=$1
    [ -d "$STAGE" ] || fail 'deployment stage is missing'
    [ -n "$TEST_ROOT" ] || check_root
    case "$STAGE" in /tmp/laputa-mirror-upload.*|/tmp/laputa-mirror-test.*) ;; *) fail 'deployment stage path is outside its temporary directory';; esac
    acquire_lock
    reject_links "$STAGE"
    ROOT_STAGE=$(mktemp -d /tmp/laputa-mirror-root.XXXXXX) || fail 'could not create root-owned staging directory'
    cp -R "$STAGE/." "$ROOT_STAGE/"
    STAGE=$ROOT_STAGE

    RELEASE_ID=$(cat "$STAGE/host/release-id") || fail 'deployment bundle has no release ID'
    valid_release_id "$RELEASE_ID" || fail 'deployment bundle has a malformed release ID'
    HOSTNAME=$(cat "$STAGE/host/hostname") || fail 'deployment bundle has no hostname'
    case "$HOSTNAME" in ''|*[!A-Za-z0-9.-]*|*..*) fail 'deployment bundle hostname is malformed' ;; esac
    LISTEN_ADDR=$(cat "$STAGE/host/listen-addr") || fail 'deployment bundle has no listen address'
    case "$LISTEN_ADDR" in 127.0.0.1:[0-9]*) ;; *) fail 'deployment bundle listen address is malformed' ;; esac
    LOCAL_HEALTH_URL=http://$LISTEN_ADDR/health
    export HOSTNAME LOCAL_HEALTH_URL

    if [ -d "$STAGE/release" ]; then
        verify_release "$STAGE/release" "$RELEASE_ID"
    fi
    [ -f "$STAGE/host/env" ] || fail 'deployment bundle is missing host configuration'
    [ -f "$STAGE/host/credentials/s3-access-key-id" ] || fail 'deployment bundle is missing the S3 access key ID'
    [ -f "$STAGE/host/credentials/s3-secret-access-key" ] || fail 'deployment bundle is missing the S3 secret access key'
    [ -f "$STAGE/host/credentials/tunnel-token" ] || fail 'deployment bundle is missing the Cloudflare Tunnel token'
    [ -f "$STAGE/host/units/laputa-mirror.service" ] || fail 'deployment bundle is missing laputa-mirror.service'
    [ -f "$STAGE/host/units/laputa-cloudflared.service" ] || fail 'deployment bundle is missing laputa-cloudflared.service'
    [ -f "$STAGE/host/sysusers/laputa-mirror.conf" ] || fail 'deployment bundle is missing the laputa-mirror sysusers declaration'

    check_id=$(check_installed_release "$RELEASE_ID")
    if [ "$check_id" = missing ]; then
        [ -d "$STAGE/release" ] || fail 'release is absent on the host and missing from the bundle'
    fi
    install_root=$(managed_path /opt/laputa-mirror)
    RELEASES_DIR=$(managed_path /opt/laputa-mirror/releases)
    ETC_MIRROR=$(managed_path /etc/laputa-mirror)
    ETC_CREDENTIALS=$(managed_path /etc/laputa-mirror/credentials)
    ETC_CLOUDFLARED=$(managed_path /etc/laputa-cloudflared)
    SYSUSERS_DIR=$(managed_path /etc/sysusers.d)
    MIRROR_UNIT=$(managed_path /etc/systemd/system/laputa-mirror.service)
    CLOUDFLARED_UNIT=$(managed_path /etc/systemd/system/laputa-cloudflared.service)
    SYSUSERS_FILE=$(managed_path /etc/sysusers.d/laputa-mirror.conf)
    ENV_FILE=$(managed_path /etc/laputa-mirror/env)
    S3_KEY_FILE=$(managed_path /etc/laputa-mirror/credentials/s3-access-key-id)
    S3_SECRET_FILE=$(managed_path /etc/laputa-mirror/credentials/s3-secret-access-key)
    TUNNEL_TOKEN_FILE=$(managed_path /etc/laputa-cloudflared/token)
    CURRENT=$(managed_path /opt/laputa-mirror/current)
    LOCAL_HEALTH_URL=http://$LISTEN_ADDR/health
    PREVIOUS_ID=$(read_current_id)

    ensure_directory "$install_root" 755 root root
    ensure_directory "$RELEASES_DIR" 755 root root
    ensure_directory "$ETC_MIRROR" 755 root root
    ensure_directory "$ETC_CREDENTIALS" 700 root root
    ensure_directory "$ETC_CLOUDFLARED" 700 root root
    ensure_directory "$SYSUSERS_DIR" 755 root root
    ensure_directory "$(managed_path /var/lib/laputa-mirror)" 700 laputa-mirror laputa-mirror
    ensure_directory "$(managed_path /var/lib/laputa-mirror/uploads)" 700 laputa-mirror laputa-mirror
    if [ -z "$TEST_ROOT" ]; then
        chown root:root "$install_root" "$RELEASES_DIR" "$ETC_MIRROR" "$ETC_CREDENTIALS" "$ETC_CLOUDFLARED" "$SYSUSERS_DIR"
        chown laputa-mirror:laputa-mirror "$(managed_path /var/lib/laputa-mirror)" "$(managed_path /var/lib/laputa-mirror/uploads)"
    fi

    BACKUP_DIR=$(mktemp -d /tmp/laputa-mirror-backup.XXXXXX) || fail 'could not create host rollback backup'
    : >"$BACKUP_DIR/existing-files"
    capture_file "$MIRROR_UNIT" mirror-unit
    capture_file "$CLOUDFLARED_UNIT" cloudflared-unit
    capture_file "$SYSUSERS_FILE" sysusers-file
    capture_file "$ENV_FILE" env-file
    capture_file "$S3_KEY_FILE" s3-key
    capture_file "$S3_SECRET_FILE" s3-secret
    capture_file "$TUNNEL_TOKEN_FILE" tunnel-token

    PREVIOUS_APP_ENABLED=no
    if systemctl is-enabled laputa-mirror.service >/dev/null 2>&1; then PREVIOUS_APP_ENABLED=yes; fi
    TRANSACTION_STARTED=yes
    APP_COMMITTED=no
    transaction_units_changed=no
    mirror_changed=no
    cloudflared_changed=no
    install_if_changed "$STAGE/host/sysusers/laputa-mirror.conf" "$SYSUSERS_FILE" 644 'laputa-mirror sysusers' || fail 'could not install the Laputa sysusers declaration'
    install_if_changed "$STAGE/host/units/laputa-mirror.service" "$MIRROR_UNIT" 644 'laputa-mirror.service' || fail 'could not install laputa-mirror.service'
    if [ "$INSTALL_CHANGED" = yes ]; then
        transaction_units_changed=yes
        mirror_changed=yes
    fi
    install_if_changed "$STAGE/host/units/laputa-cloudflared.service" "$CLOUDFLARED_UNIT" 644 'laputa-cloudflared.service' || fail 'could not install laputa-cloudflared.service'
    if [ "$INSTALL_CHANGED" = yes ]; then
        transaction_units_changed=yes
        cloudflared_changed=yes
    fi
    install_if_changed "$STAGE/host/env" "$ENV_FILE" 600 'mirror configuration' || fail 'could not install mirror configuration'
    if [ "$INSTALL_CHANGED" = yes ]; then mirror_changed=yes; fi
    install_if_changed "$STAGE/host/credentials/s3-access-key-id" "$S3_KEY_FILE" 600 'S3 access key credential' || fail 'could not install the S3 access key credential'
    if [ "$INSTALL_CHANGED" = yes ]; then mirror_changed=yes; fi
    install_if_changed "$STAGE/host/credentials/s3-secret-access-key" "$S3_SECRET_FILE" 600 'S3 secret key credential' || fail 'could not install the S3 secret key credential'
    if [ "$INSTALL_CHANGED" = yes ]; then mirror_changed=yes; fi
    install_if_changed "$STAGE/host/credentials/tunnel-token" "$TUNNEL_TOKEN_FILE" 600 'Cloudflare Tunnel credential' || fail 'could not install the Cloudflare Tunnel credential'
    if [ "$INSTALL_CHANGED" = yes ]; then cloudflared_changed=yes; fi

    systemd-sysusers "$SYSUSERS_FILE" || fail 'systemd-sysusers could not ensure the service account'
    if [ "$transaction_units_changed" = yes ]; then
        systemctl daemon-reload || fail 'systemd daemon reload failed'
    fi
    install_release "$STAGE/release" "$RELEASE_ID"
    activate_release "$RELEASE_ID" || fail 'could not activate the mirror release'
    if [ "$ACTIVATED" = yes ]; then mirror_changed=yes; fi
    systemd-analyze verify "$MIRROR_UNIT" "$CLOUDFLARED_UNIT" >/dev/null || fail 'systemd rejected a Laputa service unit'

    if [ "$PREVIOUS_APP_ENABLED" != yes ]; then
        systemctl enable laputa-mirror.service >/dev/null || fail 'could not enable laputa-mirror.service'
        say '+   enabled laputa-mirror.service'
    fi
    if [ "$mirror_changed" = yes ] || ! systemctl is-active laputa-mirror.service >/dev/null 2>&1; then
        if systemctl is-active laputa-mirror.service >/dev/null 2>&1; then
            systemctl restart laputa-mirror.service || { show_mirror_journal; fail 'laputa-mirror.service restart failed'; }
            say '~   restarted laputa-mirror.service'
        else
            systemctl start laputa-mirror.service || { show_mirror_journal; fail 'laputa-mirror.service start failed'; }
            say '+   started laputa-mirror.service'
        fi
    else
        say '=   laputa-mirror.service already active'
    fi
    systemctl is-active laputa-mirror.service >/dev/null 2>&1 || { show_mirror_journal; fail 'laputa-mirror.service is not active'; }
    wait_local_health || { show_mirror_journal; fail "$LOCAL_HEALTH_URL did not become healthy"; }
    say 'ok  local mirror health'
    APP_COMMITTED=yes

    if ! systemctl is-enabled laputa-cloudflared.service >/dev/null 2>&1; then
        systemctl enable laputa-cloudflared.service >/dev/null || fail 'could not enable laputa-cloudflared.service'
        say '+   enabled laputa-cloudflared.service'
    fi
    if [ "$cloudflared_changed" = yes ] || ! systemctl is-active laputa-cloudflared.service >/dev/null 2>&1; then
        if systemctl is-active laputa-cloudflared.service >/dev/null 2>&1; then
            systemctl restart laputa-cloudflared.service || fail 'laputa-cloudflared.service restart failed; inspect its journal'
            say '~   restarted laputa-cloudflared.service'
        else
            systemctl start laputa-cloudflared.service || fail 'laputa-cloudflared.service start failed; inspect its journal'
            say '+   started laputa-cloudflared.service'
        fi
    else
        say '=   laputa-cloudflared.service already active'
    fi
    systemctl is-active laputa-cloudflared.service >/dev/null 2>&1 || fail 'laputa-cloudflared.service is not active'
    say 'ok  laputa-cloudflared.service'
    TRANSACTION_STARTED=no
}

garbage_collect() {
    [ "$#" -eq 3 ] || fail 'usage: remote-apply.sh --gc CURRENT_ID PREVIOUS_ID'
    check_root
    acquire_lock
    current_id=$2
    previous_id=$3
    valid_release_id "$current_id" || fail 'invalid GC current release ID'
    [ -z "$previous_id" ] || valid_release_id "$previous_id" || fail 'invalid GC previous release ID'
    releases_path=$(managed_path /opt/laputa-mirror/releases)
    current_path=$(managed_path /opt/laputa-mirror/current)
    [ -L "$current_path" ] && [ "$(readlink "$current_path")" = "releases/$current_id" ] || fail 'GC refused because current does not point at the requested release'
    order_file=$(mktemp /tmp/laputa-mirror-gc.XXXXXX) || fail 'could not create GC order file'
    trap 'rm -f "$order_file"' 0 HUP INT TERM
    find "$releases_path" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | LC_ALL=C sort -rn >"$order_file"
    protected_count=1
    [ -z "$previous_id" ] || [ "$previous_id" = "$current_id" ] || protected_count=2
    extra_keep=$((3 - protected_count))
    kept_extra=0
    while IFS=' ' read -r _ candidate; do
        [ -n "$candidate" ] || continue
        if [ "$candidate" = "$current_id" ] || [ "$candidate" = "$previous_id" ]; then
            continue
        fi
        valid_release_id "$candidate" || continue
        if [ "$kept_extra" -lt "$extra_keep" ]; then
            kept_extra=$((kept_extra + 1))
            continue
        fi
        candidate_path="$releases_path/$candidate"
        [ -d "$candidate_path" ] && [ ! -L "$candidate_path" ] || continue
        rm -rf "$candidate_path"
        say "-   release $candidate"
    done <"$order_file"
    rm -f "$order_file"
    trap - 0 HUP INT TERM
}

acquire_lock() {
    lock_path=$(managed_path /run/lock/laputa-mirror-deploy.lock)
    lock_dir=$(managed_path /run/lock)
    mkdir -p "$lock_dir"
    exec 9>"$lock_path"
    flock -x 9 || fail 'could not acquire the Laputa mirror deployment lock'
}

main() {
    TRANSACTION_STARTED=no
    APP_COMMITTED=no
    BACKUP_DIR=
    ROOT_STAGE=
    PREVIOUS_APP_ENABLED=no
    trap on_exit 0 HUP INT TERM
    if [ "${1-}" = --check-release ]; then check_release_probe "$@"; return; fi
    if [ "${1-}" = --current-release ]; then check_current_probe "$@"; return; fi
    if [ "${1-}" = --mirror-runtime ]; then remote_mirror_runtime "$@"; return; fi
    if [ "${1-}" = --retire-old ]; then remote_retire_legacy "$@"; return; fi
    if [ "${1-}" = --gc ]; then garbage_collect "$@"; return; fi
    [ "$#" -eq 1 ] || fail 'usage: remote-apply.sh STAGE_DIRECTORY'
    check_root
    apply_bundle "$1"
}

main "$@"
