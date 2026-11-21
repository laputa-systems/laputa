# Containers run under the CPUs a host-wide cpu-slot grant pinned this job to;
# docker run otherwise starts them on every host CPU.
docker() {
    if [[ "${1:-}" == run && -n "${CPU_SLOT_CPUS:-}" ]]; then
        shift
        command docker run --cpuset-cpus="$CPU_SLOT_CPUS" "$@"
    else
        command docker "$@"
    fi
}
