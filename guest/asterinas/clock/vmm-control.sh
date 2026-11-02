#!/usr/bin/env bash
set -euo pipefail

action="$1"
case "$LAPUTA_PEER_BACKEND:$action" in
    asterinas:pause) state=Paused ;;
    asterinas:resume) state=Resumed ;;
    linux:pause) control=stop ;;
    linux:resume) control=cont ;;
    *) printf 'vmm-control: unsupported %s %s\n' "$LAPUTA_PEER_BACKEND" "$action" >&2; exit 2 ;;
esac
if [[ "$LAPUTA_PEER_BACKEND" == asterinas ]]; then
    curl --silent --show-error --fail --unix-socket "$LAPUTA_VMM_CONTROL" --request PATCH \
        --header 'Content-Type: application/json' --data "{\"state\": \"$state\"}" http://localhost/vm
else
    XSH_MODULE_PATH="$LAPUTA_PEER_REPO" "$LAPUTA_PEER_XSH" "$(dirname "${BASH_SOURCE[0]}")/qmp-control.xsh" -- "$LAPUTA_VMM_CONTROL" "$control"
fi
