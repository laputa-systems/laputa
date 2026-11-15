#!/usr/bin/env bash
set -euo pipefail
source "$1/infra/asterinas/inputs.lock"
[[ "$XSH_COMMIT" =~ ^[0-9a-f]{40}$ ]]
printf '%s\n' "$XSH_COMMIT"
