#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# == 2 || $# == 4 && "${3:-}" == --baseline ]] || {
    printf 'usage: account-native.sh DISCOVERED_IDS_JSON RESULT_DIR [--baseline ACCOUNTING_JSON]\n' >&2
    exit 2
}
discovered="$1"
result_dir="$2"
baseline="${4:-}"
[[ -s "$discovered" ]] || { printf 'account-native: discovered identities are missing: %s\n' "$discovered" >&2; exit 1; }
[[ -f "$result_dir/interrupted.txt" ]] || { printf 'account-native: not a native batch result directory: %s\n' "$result_dir" >&2; exit 1; }

shopt -s nullglob
logs=("$result_dir"/*.console.log)
(( ${#logs[@]} > 0 )) || { printf 'account-native: no console logs in %s\n' "$result_dir" >&2; exit 1; }
for log in "${logs[@]}"; do
    sed 's/\x1b\[[0-9;]*m//g' "$log" | tr -d '\r'
done | jaq -R -s --slurpfile ids "$discovered" --rawfile interrupted "$result_dir/interrupted.txt" \
    -f "$repo_root/infra/asterinas/account-native.jaq" > "$result_dir/accounting.json"

jaq -r '"discovered \(.discovered) passed \(.passed | length) failed \(.failed | length) skipped \(.skipped | length) unexecuted \(.unexecuted | length) unknown \(.unknown | length)"' "$result_dir/accounting.json"
status=0
jaq -e '.discovered > 0 and ((.passed | length) + (.failed | length) + (.skipped | length)) > 0 and (.unknown | length) == 0' \
    "$result_dir/accounting.json" > /dev/null || {
    printf 'account-native: no discovered cases, no results, or results for unknown cases\n' >&2
    status=1
}
if [[ -n "$baseline" ]]; then
    lost="$(jaq -r --slurpfile base "$baseline" '($base[0].passed - .passed)[]' "$result_dir/accounting.json")"
    if [[ -n "$lost" ]]; then
        printf 'account-native: cases that passed at the baseline no longer pass:\n%s\n' "$lost" >&2
        status=1
    fi
fi
exit "$status"
