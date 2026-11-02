#!/usr/bin/env bash
set -euo pipefail

mode="$1"
staged="$2"
[[ "$mode" == pause || "$mode" == jump ]] || exit 0
exec "$staged/ntp-peer" 192.0.2.1 "$staged/vmm-control.sh" "$staged/peer-ready"
