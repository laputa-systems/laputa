#!/usr/bin/env bash
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)
image=${1:?usage: ntpd_privileges.sh IMAGE SEED}
seed=${2:?usage: ntpd_privileges.sh IMAGE SEED}
mkdir -p "$repo/.work/tmp"
scratch=$(mktemp -d "$repo/.work/tmp/ntpd-privileges.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/daemon" <<'DAEMON'
#!/bin/sh
id
cat /proc/self/status
DAEMON
chmod 755 "$scratch/daemon"
cat > "$scratch/ctl" <<'CTL'
#!/bin/sh
printf 'no stratum\n'
CTL
chmod 755 "$scratch/ctl"
cat > "$scratch/notify" <<'NOTIFY'
#!/bin/sh
printf x > "/proc/self/fd/$NOTIFY_FD"
NOTIFY
chmod 755 "$scratch/notify"
printf 'root:x:0:0:root:/root:/bin/sh\nintruder:x:123:123:Other:/var/empty:/bin/false\n' > "$scratch/bad-passwd"
common=(--rm --network none
  --mount "type=bind,src=$seed/xsh,dst=/bin/xsh,readonly"
  --mount "type=bind,src=$seed/core,dst=/usr/lib/xsh/core,readonly"
  --mount "type=bind,src=$repo/packages/ntpd-rs/launch.xsh,dst=/launch.xsh,readonly"
  --mount "type=bind,src=$repo/packages/baselayout/files/rootfs/etc/group,dst=/etc/group,readonly")
output=$(docker run "${common[@]}" --cap-add SYS_TIME \
  --mount "type=bind,src=$repo/packages/baselayout/files/rootfs/etc/passwd,dst=/etc/passwd,readonly" \
  --mount "type=bind,src=$scratch/daemon,dst=/usr/bin/ntp-daemon,readonly" \
  "$image" /bin/xsh /launch.xsh)
printf '%s\n' "$output" | rg -q '^uid=123\(ntpd-rs\) gid=123\(ntpd-rs\)'
for field in CapInh CapPrm CapEff CapBnd CapAmb; do
  printf '%s\n' "$output" | rg -q "^${field}:[[:space:]]+0000000002000000$"
done
printf '%s\n' "$output" | rg -q '^Groups:[[:space:]]*$'
printf '%s\n' "$output" | rg -q '^NoNewPrivs:[[:space:]]+1$'
docker run "${common[@]}" --cap-add SYS_TIME \
  --mount "type=bind,src=$repo/packages/baselayout/files/rootfs/etc/passwd,dst=/etc/passwd,readonly" \
  --mount "type=bind,src=$scratch/daemon,dst=/usr/bin/ntp-daemon,readonly" \
  "$image" /bin/sh -c '
  mkdir -p /var/lib/ntpd-rs
  chmod 0755 /var/lib/ntpd-rs
  if /bin/xsh /launch.xsh; then exit 1; fi
  test "$(stat -c "%u:%g %a" /var/lib/ntpd-rs)" = "0:0 755"
'
docker run "${common[@]}" --mount "type=bind,src=$scratch/bad-passwd,dst=/etc/passwd,readonly" "$image" /bin/sh -c '
  mkdir /run/ntpd-rs
  chmod 0711 /run/ntpd-rs
  if /bin/xsh /launch.xsh; then exit 1; fi
  test "$(stat -c "%u:%g %a" /run/ntpd-rs)" = "0:0 711"
'
ready=$(docker run "${common[@]}" --cap-add SYS_TIME \
  --mount "type=bind,src=$repo/packages/baselayout/files/rootfs/etc/passwd,dst=/etc/passwd,readonly" \
  --mount "type=bind,src=$scratch/notify,dst=/usr/bin/ntp-daemon,readonly" \
  "$image" /bin/sh -c 'set -o pipefail; (NOTIFY_FD=3 /bin/xsh /launch.xsh 3>&1 1>&2) | cat')
test "$ready" = x
docker run "${common[@]}" \
  --mount "type=bind,src=$repo/packages/baselayout/files/rootfs/etc/passwd,dst=/etc/passwd,readonly" \
  "$image" /bin/sh -c '
  exec 3> /tmp/not-a-pipe
  if NOTIFY_FD=3 /bin/xsh /launch.xsh; then exit 1; fi
  test "$(stat -c "%u:%g" /tmp/not-a-pipe)" = "0:0"
  mkfifo /tmp/named-pipe
  exec 4<> /tmp/named-pipe
  if NOTIFY_FD=4 /bin/xsh /launch.xsh; then exit 1; fi
  test "$(stat -c "%u:%g" /tmp/named-pipe)" = "0:0"
'
docker run "${common[@]}" \
  --mount "type=bind,src=$repo/packages/ntpd-rs/service.xsh,dst=/service.xsh,readonly" \
  --mount "type=bind,src=$repo/tests/docker/fixtures/ntpd_status.xsh,dst=/test.xsh,readonly" \
  --mount "type=bind,src=$scratch/ctl,dst=/usr/bin/ntp-ctl,readonly" \
  "$image" /bin/xsh /test.xsh
printf 'ntpd privilege boundary passed\n'
