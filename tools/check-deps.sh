#!/bin/sh
# R1: production dependency gate. Only libc (plus the workspace itself) may
# appear as a normal dependency; dev-dependencies are unrestricted.
# Production deps allowed by the campaign: std, libc, rustix + transitives.
# Decision R1: libc alone suffices (regex_t layout, mknod, netlink, pwd/grp
# all covered); rustix adds nothing needed, so it stays out.
set -eu
allow="^mdevd v|^libc v"
bad=$(cargo tree --offline -e normal --prefix none 2>/dev/null | grep -Ev "$allow" || true)
if [ -n "$bad" ]; then
  echo "check-deps: forbidden production dependency:" >&2
  echo "$bad" >&2
  exit 1
fi
echo "check-deps: production deps OK (libc only)"
