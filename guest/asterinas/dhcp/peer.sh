#!/usr/bin/env bash
set -euo pipefail

mode="$1"
staged="$2"
export XSH_MODULE_PATH="$LAPUTA_PEER_CORE"
script="$staged/server-script.json"
"$LAPUTA_PEER_XSH" "$staged/server-script.xsh" -- "$mode" "$script"
if [[ "$mode" == tcp ]]; then
    "$staged/peer-tcp" > "$staged/peer-tcp.log" 2>&1 &
fi
exec "$LAPUTA_PEER_XSH" "$LAPUTA_PEER_CORE/tests/support/dhcp_server.xsh" -- tap0 "$script" "$staged/server.requests"
