cancellable_child=""
cancellable_container=""
cancellable_spawning=""
cancellable_pending=""
cancellable_grace="${LAPUTA_CANCEL_GRACE_SECONDS:-20}"

cancellable_remove_container() {
    local attempts="$1" attempt
    [[ -n "$cancellable_container" ]] || return 0
    for ((attempt = 0; attempt < attempts; attempt++)); do
        docker rm -f "$cancellable_container" > /dev/null 2>&1 && break
        (( attempt + 1 == attempts )) || sleep 0.2
    done
}

cancellable_stop() {
    local removed=0 tick
    if [[ -n "$cancellable_container" ]] && docker rm -f "$cancellable_container" > /dev/null 2>&1; then
        removed=1
    fi
    if [[ -n "$cancellable_child" ]]; then
        if kill -0 "$cancellable_child" 2>/dev/null; then
            kill -TERM "$cancellable_child" 2>/dev/null || true
            for ((tick = 0; tick < cancellable_grace * 10; tick++)); do
                kill -0 "$cancellable_child" 2>/dev/null || break
                sleep 0.1
            done
            kill -KILL "$cancellable_child" 2>/dev/null || true
        fi
        wait "$cancellable_child" 2>/dev/null || true
        cancellable_child=""
    fi
    (( removed )) || cancellable_remove_container 5
    cancellable_container=""
}

cancellable_abort() {
    cancellable_stop
    ! declare -F cancellable_cancelled > /dev/null || cancellable_cancelled
    exit "$1"
}

cancellable_signal() {
    if [[ -n "$cancellable_spawning" ]]; then
        cancellable_pending="$1"
        return 0
    fi
    cancellable_abort "$1"
}

run_cancellable() {
    cancellable_container="$1"
    shift
    local status=0
    cancellable_spawning=1
    LAPUTA_CANCEL_GRACE_SECONDS=$(( cancellable_grace > 3 ? cancellable_grace - 3 : 1 )) env --default-signal=INT "$@" &
    cancellable_child=$!
    cancellable_spawning=""
    [[ -z "$cancellable_pending" ]] || cancellable_abort "$cancellable_pending"
    wait "$cancellable_child" || status=$?
    cancellable_child=""
    cancellable_remove_container 1
    cancellable_container=""
    return "$status"
}

trap 'cancellable_signal 143' TERM
trap 'cancellable_signal 130' INT
trap cancellable_stop EXIT
