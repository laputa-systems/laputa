#!/bin/bash
set -euo pipefail

finish() {
    native_status=$?
    trap - EXIT
    if (( native_status == 0 )); then
        printf 'XSH_NATIVE_RESULT pass\n'
    else
        printf 'XSH_NATIVE_RESULT fail status=%s\n' "$native_status"
    fi
    sync
    /sbin/poweroff -f
    exit "$native_status"
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while IFS= read -r native_environment; do
    export "$native_environment"
done < /etc/xsh-native.env
export PATH=/usr/local/bin:/root/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin
export TARGET=x86_64-unknown-linux-musl
export CARGO_TARGET_DIR=/work/target
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=/usr/local/bin/xsh-mold-linker
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS='-C target-feature=+crt-static -C link-arg=-Wl,--defsym=__isoc23_sscanf=sscanf -C link-arg=-Wl,--defsym=__isoc23_strtol=strtol'

mkdir -p /dev/pts /dev/shm /run /tmp
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /tmp
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /dev/shm
mount -t devpts -o mode=0620,gid=5,ptmxmode=0666,nosuid,noexec devpts /dev/pts
ln -sfn pts/ptmx /dev/ptmx
ln -sfn /proc/self/fd /dev/fd
ln -sfn fd/0 /dev/stdin
ln -sfn fd/1 /dev/stdout
ln -sfn fd/2 /dev/stderr
ip link set lo up
hostname xsh-qualification

mkdir -p /run/xsh-native /work/.work/tmp/native/home /work/.work/tmp/native/tmp
chown -R 1000:1000 /work/.work/tmp/native
chmod 700 /work/.work/tmp/native /work/.work/tmp/native/home /work/.work/tmp/native/tmp
touch /work/.work/tmp/native/xsht-config.ini
chown 1000:1000 /work/.work/tmp/native/xsht-config.ini

native_user=(setsid --wait setpriv --reuid=1000 --regid=1000 --clear-groups env
    HOME=/work/.work/tmp/native/home
    TMPDIR=/work/.work/tmp/native/tmp
    XDG_CACHE_HOME=/work/.work/tmp/native/home/.cache
    CARGO_BIN_EXE_xsh=/usr/bin/xsh
    CARGO_BIN_EXE_xsht=/usr/bin/xsht)
[[ "$("${native_user[@]}" id -u)" == 1000 ]]
[[ "$("${native_user[@]}" id -g)" == 1000 ]]
"${native_user[@]}" /bin/bash -c 'test ! -w /etc/passwd; test -x /usr/bin/perl; test -x /usr/bin/clang-23'
printf 'XSH_NATIVE_CONTEXT uid=1000 gid=1000 jobs=1\n'

cd /work
native_failed=0
native_count=0
while IFS= read -r native_selection || [[ -n "$native_selection" ]]; do
    [[ -n "$native_selection" ]] || continue
    native_count=$((native_count + 1))
    native_arguments=()
    if [[ "$native_selection" != all ]]; then
        native_arguments=(--exact "$native_selection")
    fi
    printf 'XSH_NATIVE_START %s\n' "$native_selection"
    set +e
    "${native_user[@]}" /usr/bin/xsht test --jobs 1 --nocapture "${native_arguments[@]}" 2>&1 | tee "/run/xsh-native/$native_count.log"
    native_status=${PIPESTATUS[0]}
    set -e
    if (( native_status != 0 )) || ! awk '/^running [1-9][0-9]* tests$/ { found=1 } END { exit !found }' "/run/xsh-native/$native_count.log"; then
        native_failed=1
    fi
done < /etc/xsh-native.selection

(( native_count > 0 && native_failed == 0 ))
