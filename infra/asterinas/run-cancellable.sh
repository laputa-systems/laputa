cancellable_child=""
cancellable_container=""

cancellable_stop() {
    if [[ -n "$cancellable_container" ]]; then
        docker rm -f "$cancellable_container" > /dev/null 2>&1 || true
        cancellable_container=""
    fi
    if [[ -n "$cancellable_child" ]]; then
        if kill -0 "$cancellable_child" 2>/dev/null; then
            kill -TERM "$cancellable_child" 2>/dev/null || true
            for _ in {1..100}; do
                kill -0 "$cancellable_child" 2>/dev/null || break
                sleep 0.1
            done
            kill -KILL "$cancellable_child" 2>/dev/null || true
        fi
        wait "$cancellable_child" 2>/dev/null || true
        cancellable_child=""
    fi
}

run_cancellable() {
    cancellable_container="$1"
    shift
    "$@" &
    cancellable_child=$!
    local status=0
    wait "$cancellable_child" || status=$?
    cancellable_child=""
    cancellable_container=""
    return "$status"
}

trap 'cancellable_stop; exit 143' TERM
trap 'cancellable_stop; exit 130' INT
trap cancellable_stop EXIT
