#!/bin/sh
set -eu
umask 077

fail() {
    printf 'Cloudflare: %s\n' "$*" >&2
    exit 1
}

say() {
    printf '%s\n' "$*"
}

require_values() {
    [ -n "${CF_ACCOUNT_ID-}" ] || fail 'CF_ACCOUNT_ID was not resolved'
    [ -n "${MIRROR_HOSTNAME-}" ] || fail 'MIRROR_HOSTNAME is unset'
    [ -n "${MIRROR_R2_BUCKET-}" ] || fail 'MIRROR_R2_BUCKET is unset'
    [ -n "${MIRROR_CF_TUNNEL-}" ] || fail 'MIRROR_CF_TUNNEL is unset'
    [ -n "${MIRROR_LISTEN_ADDR-}" ] || fail 'MIRROR_LISTEN_ADDR is unset'
}

cf_run() {
    CLOUDFLARE_ACCOUNT_ID=$CF_ACCOUNT_ID cf "$@"
}

valid_uuid() {
    case "$1" in
        ????????-????-????-????-????????????) case "$1" in *[!0-9a-f-]*) return 1 ;; esac ;;
        *) return 1 ;;
    esac
    return 0
}

zone_for_hostname() {
    zone_json=$1
    zone_candidate=$MIRROR_HOSTNAME
    while [ -n "$zone_candidate" ]; do
        cf zones list --account-id "$CF_ACCOUNT_ID" --name "$zone_candidate" --status active --per-page 1000 >"$zone_json" ||
            fail 'could not list Cloudflare zones in CF_ACCOUNT_ID'
        zone_matches=$(jq --arg account "$CF_ACCOUNT_ID" --arg name "$zone_candidate" \
            '[.[] | select(.account.id == $account and .name == $name and .status == "active")] | length' "$zone_json") ||
            fail 'cf zones list did not return JSON'
        [ "$zone_matches" -le 1 ] || fail "multiple active Cloudflare zones match $zone_candidate"
        if [ "$zone_matches" -eq 1 ]; then
            jq -e --arg account "$CF_ACCOUNT_ID" --arg name "$zone_candidate" \
                '.[] | select(.account.id == $account and .name == $name and .status == "active")' \
                "$zone_json" >"$STATE_DIR/zone.json" || fail 'the selected zone belongs to another account'
            break
        fi
        case "$zone_candidate" in *.*) zone_candidate=${zone_candidate#*.} ;; *) zone_candidate= ;; esac
    done
    [ -s "$STATE_DIR/zone.json" ] || fail 'no active Cloudflare zone in CF_ACCOUNT_ID owns MIRROR_HOSTNAME'
    zone_matches=1
    jq -er '.id' "$STATE_DIR/zone.json" >"$STATE_DIR/zone-id" || fail 'Cloudflare zone response has no ID'
}

tunnel_by_id() {
    tunnel_id=$1
    jq --arg id "$tunnel_id" '[.[] | select(.id == $id and .deleted_at == null)] | .[0] // empty' "$STATE_DIR/tunnels.json"
}

is_mirror_ingress() {
    config_file=$1
    allowed_services=$2
    jq -e --arg host "$MIRROR_HOSTNAME" '
        (.config.ingress | type == "array" and length == 2)
        and .config.ingress[0].hostname == $host
        and .config.ingress[1].service == "http_status:404"
        and ([.config.ingress[].hostname // empty] | length == 1)
    ' "$config_file" >/dev/null 2>&1 || return 1
    service=$(jq -r '.config.ingress[0].service' "$config_file")
    case "|$allowed_services|" in *"|$service|"*) return 0 ;; *) return 1 ;; esac
}

save_tunnel_config() {
    tunnel_id=$1
    destination=$2
    cf_run tunnels config get "$tunnel_id" >"$destination" || fail "could not read configuration for tunnel $tunnel_id"
}

preflight() {
    STATE_DIR=$1
    export STATE_DIR
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    require_values

    cf accounts list >"$STATE_DIR/accounts.json" || fail 'cf authentication failed; run cf auth login or provide CLOUDFLARE_API_TOKEN'
    jq -e --arg account "$CF_ACCOUNT_ID" '[.[] | select(.id == $account)] | length == 1' "$STATE_DIR/accounts.json" >/dev/null ||
        fail 'CF_ACCOUNT_ID is not available to the authenticated cf profile'

    zone_for_hostname "$STATE_DIR/zones.json"
    zone_id=$(cat "$STATE_DIR/zone-id")
    zone_account=$(jq -er '.account.id' "$STATE_DIR/zone.json")
    [ "$zone_account" = "$CF_ACCOUNT_ID" ] || fail 'the selected hostname zone belongs to another account'

    cf_run r2 buckets list --name-contains "$MIRROR_R2_BUCKET" --per-page 1000 >"$STATE_DIR/buckets.json" ||
        fail 'could not list R2 buckets in CF_ACCOUNT_ID'
    bucket_count=$(jq --arg bucket "$MIRROR_R2_BUCKET" '[.buckets[] | select(.name == $bucket)] | length' "$STATE_DIR/buckets.json") ||
        fail 'cf r2 buckets list did not return JSON'
    [ "$bucket_count" -le 1 ] || fail 'Cloudflare returned duplicate exact-name R2 buckets'

    cf_run tunnels list --per-page 1000 >"$STATE_DIR/tunnels.json" || fail 'could not list Cloudflare tunnels in CF_ACCOUNT_ID'
    tunnel_count=$(jq --arg name "$MIRROR_CF_TUNNEL" --arg account "$CF_ACCOUNT_ID" \
        '[.[] | select(.name == $name and .account_tag == $account and .deleted_at == null)] | length' "$STATE_DIR/tunnels.json") ||
        fail 'cf tunnels list did not return JSON'
    [ "$tunnel_count" -le 1 ] || fail 'multiple Cloudflare tunnels have the configured MIRROR_CF_TUNNEL name'
    target_id=$(jq -r --arg name "$MIRROR_CF_TUNNEL" --arg account "$CF_ACCOUNT_ID" \
        '[.[] | select(.name == $name and .account_tag == $account and .deleted_at == null)][0].id // empty' "$STATE_DIR/tunnels.json")
    if [ -n "$target_id" ]; then
        target_tunnel=$(tunnel_by_id "$target_id")
        [ "$(printf '%s' "$target_tunnel" | jq -r '.config_src')" = cloudflare ] ||
            fail 'the configured tunnel exists but is not remotely managed by Cloudflare'
        save_tunnel_config "$target_id" "$STATE_DIR/target-config.json"
        ingress_count=$(jq -r '.config.ingress | if type == "array" then length else 0 end' "$STATE_DIR/target-config.json")
        if [ "$ingress_count" -gt 0 ] && ! is_mirror_ingress "$STATE_DIR/target-config.json" "http://$MIRROR_LISTEN_ADDR"; then
            fail 'the configured tunnel has ingress rules outside the Laputa mirror hostname; refusing to replace them'
        fi
    else
        : >"$STATE_DIR/target-config.json"
    fi

    cf dns records list --zone "$zone_id" --name-exact "$MIRROR_HOSTNAME" --per-page 100 >"$STATE_DIR/dns.json" ||
        fail 'could not read the DNS records for MIRROR_HOSTNAME'
    dns_count=$(jq 'length' "$STATE_DIR/dns.json") || fail 'cf dns records list did not return JSON'
    [ "$dns_count" -le 1 ] || fail 'multiple DNS records occupy MIRROR_HOSTNAME'

    legacy_id=
    if [ "$dns_count" -eq 1 ]; then
        record_type=$(jq -er '.[0].type' "$STATE_DIR/dns.json")
        [ "$record_type" = CNAME ] || fail 'MIRROR_HOSTNAME is occupied by a non-CNAME DNS record'
        current_content=$(jq -er '.[0].content' "$STATE_DIR/dns.json")
        case "$current_content" in
            *.cfargotunnel.com) current_id=${current_content%.cfargotunnel.com} ;;
            *) fail 'MIRROR_HOSTNAME points to a CNAME outside a Cloudflare Tunnel' ;;
        esac
        valid_uuid "$current_id" || fail 'MIRROR_HOSTNAME points to an unrecognized tunnel target'
        if [ "$current_id" != "$target_id" ]; then
            old_tunnel=$(tunnel_by_id "$current_id")
            [ -n "$old_tunnel" ] || fail 'MIRROR_HOSTNAME points to a tunnel outside CF_ACCOUNT_ID'
            [ "$(printf '%s' "$old_tunnel" | jq -r '.name')" = laputa ] ||
                fail 'MIRROR_HOSTNAME points to a different tunnel; refusing to replace an unrelated route'
            [ "$(printf '%s' "$old_tunnel" | jq -r '.config_src')" = cloudflare ] ||
                fail 'the existing Laputa tunnel is not remotely managed'
            save_tunnel_config "$current_id" "$STATE_DIR/legacy-config.json"
            is_mirror_ingress "$STATE_DIR/legacy-config.json" 'http://localhost:3000|http://127.0.0.1:3000' ||
                fail 'the existing laputa tunnel has unexpected ingress rules; refusing to replace it'
            legacy_id=$current_id
        fi
    fi

    if [ -z "$legacy_id" ]; then
        legacy_candidates=$(jq --arg target "$target_id" --arg account "$CF_ACCOUNT_ID" \
            '[.[] | select(.name == "laputa" and .account_tag == $account and .id != $target and .deleted_at == null)] | length' "$STATE_DIR/tunnels.json")
        if [ "$legacy_candidates" -gt 1 ]; then
            fail 'multiple legacy laputa tunnels exist; refusing to choose one for cleanup'
        fi
        if [ "$legacy_candidates" -eq 1 ]; then
            candidate_id=$(jq -r --arg target "$target_id" --arg account "$CF_ACCOUNT_ID" \
                '[.[] | select(.name == "laputa" and .account_tag == $account and .id != $target and .deleted_at == null)][0].id' "$STATE_DIR/tunnels.json")
            save_tunnel_config "$candidate_id" "$STATE_DIR/legacy-config.json"
            if is_mirror_ingress "$STATE_DIR/legacy-config.json" 'http://localhost:3000|http://127.0.0.1:3000'; then
                legacy_id=$candidate_id
            fi
        fi
    fi

    printf '%s\n' "$target_id" >"$STATE_DIR/target-tunnel-id"
    printf '%s\n' "$legacy_id" >"$STATE_DIR/legacy-tunnel-id"
    if [ "$bucket_count" -eq 1 ]; then say "=   R2 bucket $MIRROR_R2_BUCKET"; else say "+   R2 bucket $MIRROR_R2_BUCKET"; fi
    if [ -n "$target_id" ]; then say "=   tunnel $MIRROR_CF_TUNNEL"; else say "+   tunnel $MIRROR_CF_TUNNEL"; fi
    if [ "$dns_count" -eq 0 ]; then say "+   DNS $MIRROR_HOSTNAME"; else say "=   DNS $MIRROR_HOSTNAME (preflight only)"; fi
    if [ -n "$legacy_id" ]; then say '~   recognized legacy mirror tunnel'; fi
}

ensure_bucket() {
    bucket_count=$(jq --arg bucket "$MIRROR_R2_BUCKET" '[.buckets[] | select(.name == $bucket)] | length' "$STATE_DIR/buckets.json")
    if [ "$bucket_count" -eq 1 ]; then
        say "=   R2 bucket $MIRROR_R2_BUCKET"
        return
    fi
    body=$(jq -cn --arg name "$MIRROR_R2_BUCKET" '{name:$name, "storage-class":"Standard"}')
    cf_run r2 buckets create --body "$body" >/dev/null || fail "could not create R2 bucket $MIRROR_R2_BUCKET"
    say "+   R2 bucket $MIRROR_R2_BUCKET"
}

ensure_tunnel() {
    target_id=$(cat "$STATE_DIR/target-tunnel-id")
    if [ -z "$target_id" ]; then
        created="$STATE_DIR/created-tunnel.json"
        cf_run tunnels create --name "$MIRROR_CF_TUNNEL" --config-src cloudflare >"$created" ||
            fail "could not create remotely managed tunnel $MIRROR_CF_TUNNEL"
        target_id=$(jq -er '.id // .tunnel.id // .result.id' "$created") || fail 'Cloudflare tunnel create response has no ID'
        valid_uuid "$target_id" || fail 'Cloudflare tunnel create returned an invalid ID'
        printf '%s\n' "$target_id" >"$STATE_DIR/target-tunnel-id"
    fi
    config_body=$(jq -cn --arg host "$MIRROR_HOSTNAME" --arg service "http://$MIRROR_LISTEN_ADDR" \
        '{config:{ingress:[{hostname:$host,service:$service},{service:"http_status:404"}]}}')
    save_tunnel_config "$target_id" "$STATE_DIR/target-config.json"
    if jq -e --arg host "$MIRROR_HOSTNAME" --arg service "http://$MIRROR_LISTEN_ADDR" \
        '.config.ingress | type == "array" and length == 2 and .[0].hostname == $host and .[0].service == $service and .[1].service == "http_status:404"' \
        "$STATE_DIR/target-config.json" >/dev/null; then
        say "=   tunnel ingress $MIRROR_HOSTNAME"
    else
        cf_run tunnels config update "$target_id" --body "$config_body" >/dev/null || fail 'could not update the remotely managed tunnel ingress'
        save_tunnel_config "$target_id" "$STATE_DIR/target-config.json"
        jq -e --arg host "$MIRROR_HOSTNAME" --arg service "http://$MIRROR_LISTEN_ADDR" \
            '.config.ingress | type == "array" and length == 2 and .[0].hostname == $host and .[0].service == $service and .[1].service == "http_status:404"' \
            "$STATE_DIR/target-config.json" >/dev/null || fail 'Cloudflare did not retain the requested ingress configuration'
        say "~   tunnel ingress $MIRROR_HOSTNAME"
    fi
}

write_token() {
    tunnel_id=$(cat "$STATE_DIR/target-tunnel-id")
    token_file=$2
    raw="$STATE_DIR/tunnel-token.json"
    cf_run tunnels token get "$tunnel_id" >"$raw" || fail 'could not retrieve the tunnel runner token'
    jq -er 'if type == "string" then . elif (.token | type) == "string" then .token elif (.result | type) == "string" then .result elif (.result | type) == "object" and (.result.token | type) == "string" then .result.token else empty end | select(type == "string" and length > 0)' \
        "$raw" >"$token_file" || fail 'Cloudflare returned an unrecognized tunnel token response'
    chmod 600 "$token_file"
}

prepare() {
    STATE_DIR=$1
    token_file=$2
    preflight "$STATE_DIR"
    ensure_bucket
    ensure_tunnel
    write_token "$STATE_DIR" "$token_file"
}

verify_tunnel() {
    STATE_DIR=$1
    tunnel_id=$(cat "$STATE_DIR/target-tunnel-id")
    cf_run tunnels list --uuid "$tunnel_id" --per-page 100 >"$STATE_DIR/target-status.json" || fail 'could not verify the new tunnel connection'
    jq -e --arg id "$tunnel_id" 'any(.[]; .id == $id and .status == "healthy" and .config_src == "cloudflare")' \
        "$STATE_DIR/target-status.json" >/dev/null || fail 'laputa-mirror tunnel has no healthy Cloudflare connection'
    say 'ok  laputa-mirror tunnel connection'
}

read_jobs() {
    jobs_file=$1
    cf_run r2 buckets jobs list --bucket-name "$MIRROR_R2_BUCKET" >"$jobs_file" ||
        fail 'could not inspect R2 background jobs'
    jq -e '.jobs | type == "array"' "$jobs_file" >/dev/null ||
        fail 'R2 background job response has an unexpected shape'
}

job_status() {
    jq -er '.status // .job.status // .result.status // empty' "$1" ||
        fail 'R2 job response has no status'
}

wait_for_terminal_job() {
    job_id=$1
    result_file=$2
    while :; do
        cf_run r2 buckets jobs get "$job_id" --bucket-name "$MIRROR_R2_BUCKET" >"$result_file" ||
            fail 'could not poll the R2 bucket-empty job'
        JOB_STATUS=$(job_status "$result_file")
        case "$JOB_STATUS" in
            COMPLETED|FAILED|CANCELLED) return 0 ;;
            ENQUEUED|RUNNING) sleep 5 ;;
            *) fail 'R2 bucket-empty job returned an unknown status' ;;
        esac
    done
}

wait_for_job() {
    wait_for_terminal_job "$1" "$2"
    case "$JOB_STATUS" in
        COMPLETED) return 0 ;;
        FAILED|CANCELLED) fail "R2 bucket-empty job finished with status $JOB_STATUS" ;;
    esac
}

wait_for_empty_jobs() {
    STATE_DIR=$1
    mkdir -p "$STATE_DIR"
    while :; do
        read_jobs "$STATE_DIR/jobs.json"
        job_id=$(jq -r '[.jobs[] | select(.status == "ENQUEUED" or .status == "RUNNING") | (.id // .job_id) | select(type == "string")] | .[0] // empty' "$STATE_DIR/jobs.json") ||
            fail 'could not read active R2 job identifiers'
        [ -n "$job_id" ] || return 0
        wait_for_terminal_job "$job_id" "$STATE_DIR/job.json"
    done
}

empty_bucket() {
    STATE_DIR=$1
    mkdir -p "$STATE_DIR"
    cf_run r2 objects list --bucket-name "$MIRROR_R2_BUCKET" --per-page 1 >"$STATE_DIR/objects-before.json" ||
        fail 'could not inspect the R2 bucket before emptying it'
    object_count=$(jq -er 'if type == "array" then length else error("unexpected R2 object list") end' "$STATE_DIR/objects-before.json") ||
        fail 'R2 object list response has an unexpected shape'
    if [ "$object_count" -eq 0 ]; then
        say '=   R2 bucket already empty'
        return 0
    fi

    read_jobs "$STATE_DIR/jobs.json"
    active_jobs=$(jq '[.jobs[] | select(.status == "ENQUEUED" or .status == "RUNNING")] | length' "$STATE_DIR/jobs.json") ||
        fail 'could not count active R2 background jobs'
    [ "$active_jobs" -eq 0 ] || fail 'R2 has active background jobs; wait for them to finish and rerun deployment'

    cf_run r2 objects bulk-delete --bucket-name "$MIRROR_R2_BUCKET" --prefix '' --body '[]' --force >"$STATE_DIR/empty-job.json" ||
        fail 'Cloudflare could not start the R2 bucket-empty job'
    status=$(jq -r '.status // .job.status // .result.status // empty' "$STATE_DIR/empty-job.json") ||
        fail 'could not read the R2 bucket-empty response'
    case "$status" in
        COMPLETED)
            ;;
        ENQUEUED|RUNNING)
            job_id=$(jq -er '.id // .job.id // .result.id // empty' "$STATE_DIR/empty-job.json") ||
                fail 'Cloudflare started an R2 bucket-empty job without returning its ID'
            say '... waiting for the R2 bucket-empty job'
            wait_for_job "$job_id" "$STATE_DIR/job.json"
            ;;
        *) fail 'Cloudflare returned an unexpected R2 bucket-empty job response' ;;
    esac

    cf_run r2 objects list --bucket-name "$MIRROR_R2_BUCKET" --per-page 1 >"$STATE_DIR/objects-after.json" ||
        fail 'could not verify the R2 bucket after emptying it'
    object_count=$(jq -er 'if type == "array" then length else error("unexpected R2 object list") end' "$STATE_DIR/objects-after.json") ||
        fail 'R2 object list response has an unexpected shape after emptying it'
    [ "$object_count" -eq 0 ] || fail 'R2 still contains objects after its bucket-empty job completed'
    say '~   emptied R2 bucket contents'
}

route_dns() {
    STATE_DIR=$1
    preflight "$STATE_DIR"
    zone_id=$(cat "$STATE_DIR/zone-id")
    tunnel_id=$(cat "$STATE_DIR/target-tunnel-id")
    [ -n "$tunnel_id" ] || fail 'target tunnel was not prepared'
    desired_content=$tunnel_id.cfargotunnel.com
    dns_count=$(jq 'length' "$STATE_DIR/dns.json")
    body=$(jq -cn --arg name "$MIRROR_HOSTNAME" --arg content "$desired_content" \
        '{name:$name,type:"CNAME",content:$content,proxied:true,ttl:1}')
    if [ "$dns_count" -eq 0 ]; then
        cf dns records create --zone "$zone_id" --body "$body" >/dev/null || fail 'could not create the mirror hostname CNAME'
        say "~   DNS $MIRROR_HOSTNAME"
        return
    fi
    record_id=$(jq -er '.[0].id' "$STATE_DIR/dns.json") || fail 'existing DNS record has no ID'
    record_type=$(jq -er '.[0].type' "$STATE_DIR/dns.json")
    record_content=$(jq -er '.[0].content' "$STATE_DIR/dns.json")
    if [ "$record_type" = CNAME ] && [ "$record_content" = "$desired_content" ] && [ "$(jq -r '.[0].proxied' "$STATE_DIR/dns.json")" = true ]; then
        say "=   DNS $MIRROR_HOSTNAME"
        return
    fi
    cf dns records update "$record_id" --zone "$zone_id" --body "$body" >/dev/null || fail 'could not point the mirror hostname at the prepared tunnel'
    say "~   DNS $MIRROR_HOSTNAME"
}

retire_legacy() {
    STATE_DIR=$1
    preflight "$STATE_DIR"
    legacy_id=$(cat "$STATE_DIR/legacy-tunnel-id")
    [ -n "$legacy_id" ] || { say '=   no legacy tunnel'; return; }
    zone_id=$(cat "$STATE_DIR/zone-id")
    tunnel_id=$(cat "$STATE_DIR/target-tunnel-id")
    desired_content=$tunnel_id.cfargotunnel.com
    cf dns records list --zone "$zone_id" --name-exact "$MIRROR_HOSTNAME" --per-page 100 >"$STATE_DIR/dns-final.json" ||
        fail 'could not verify the mirror DNS route before legacy cleanup'
    jq -e --arg content "$desired_content" 'length == 1 and .[0].type == "CNAME" and .[0].content == $content and .[0].proxied == true' \
        "$STATE_DIR/dns-final.json" >/dev/null || fail 'refusing to remove the legacy tunnel before DNS points to laputa-mirror'
    attempt=0
    while [ "$attempt" -lt 20 ]; do
        cf_run tunnels list --uuid "$legacy_id" --per-page 100 >"$STATE_DIR/legacy-status.json" || fail 'could not inspect the legacy tunnel before removal'
        connections=$(jq --arg id "$legacy_id" '[.[] | select(.id == $id) | .connections[]?] | length' "$STATE_DIR/legacy-status.json")
        [ "$connections" -eq 0 ] && break
        attempt=$((attempt + 1))
        sleep 3
    done
    [ "$connections" -eq 0 ] || fail 'legacy tunnel still has active connectors; inspect Cloudflare before removing it'
    cf_run tunnels delete "$legacy_id" --force >/dev/null || fail 'could not remove the retired mirror tunnel'
    say '~   removed legacy mirror tunnel'
}

main() {
    [ "$#" -ge 2 ] || fail 'usage: cloudflare.sh preflight|prepare|verify|route|empty-bucket|wait-empty|retire STATE_DIR [TOKEN_FILE]'
    command_name=$1
    STATE_DIR=$2
    export STATE_DIR
    require_values
    case "$command_name" in
        preflight) [ "$#" -eq 2 ] || fail 'usage: cloudflare.sh preflight STATE_DIR'; preflight "$STATE_DIR" ;;
        prepare) [ "$#" -eq 3 ] || fail 'usage: cloudflare.sh prepare STATE_DIR TOKEN_FILE'; prepare "$STATE_DIR" "$3" ;;
        verify) [ "$#" -eq 2 ] || fail 'usage: cloudflare.sh verify STATE_DIR'; verify_tunnel "$STATE_DIR" ;;
        route) [ "$#" -eq 2 ] || fail 'usage: cloudflare.sh route STATE_DIR'; route_dns "$STATE_DIR" ;;
        empty-bucket) [ "$#" -eq 2 ] || fail 'usage: cloudflare.sh empty-bucket STATE_DIR'; empty_bucket "$STATE_DIR" ;;
        wait-empty) [ "$#" -eq 2 ] || fail 'usage: cloudflare.sh wait-empty STATE_DIR'; wait_for_empty_jobs "$STATE_DIR" ;;
        retire) [ "$#" -eq 2 ] || fail 'usage: cloudflare.sh retire STATE_DIR'; retire_legacy "$STATE_DIR" ;;
        *) fail "unknown operation $command_name" ;;
    esac
}

main "$@"
