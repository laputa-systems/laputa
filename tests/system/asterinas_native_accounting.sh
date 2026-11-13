#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/laputa-native-accounting.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

account_root="$scratch/account"
mkdir -p "$account_root"
printf '%s\n' \
    '["core/tests/a.xsh::t_improved","core/tests/a.xsh::t_debt","core/tests/a.xsh::t_stable","core/tests/b.xsh::t_in_flight","core/tests/b.xsh::t_late"]' \
    > "$account_root/discovered.json"
write_account_run() {
    local name="$1" improved="$2" stable="$3"
    mkdir -p "$account_root/$name"
    : > "$account_root/$name/interrupted.txt"
    printf '%s\n' \
        'LAPUTA_ASTERINAS_XSH_TEST_START core/tests/a.xsh' \
        "core/tests/a.xsh::t_improved ... $improved 10ms" \
        'core/tests/a.xsh::t_debt ... FAILED 10ms' \
        "core/tests/a.xsh::t_stable ... $stable 10ms" \
        > "$account_root/$name/1.console.log"
}
write_account_run baseline FAILED ok
write_account_run improved ok ok
write_account_run regressed FAILED FAILED
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/baseline" > /dev/null
[[ "$(jaq -c '[.passed, .failed, (.unexecuted | length)]' "$account_root/baseline/accounting.json")" == '[["core/tests/a.xsh::t_stable"],["core/tests/a.xsh::t_debt","core/tests/a.xsh::t_improved"],2]' ]]
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/improved" \
    --baseline "$account_root/baseline/accounting.json" > /dev/null
[[ "$(jaq -c '.failed' "$account_root/improved/accounting.json")" == '["core/tests/a.xsh::t_debt"]' ]]
if bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/regressed" \
    --baseline "$account_root/improved/accounting.json" > "$account_root/regressed.log" 2>&1; then
    printf 'accounting accepted a regressed case\n' >&2
    exit 1
fi
rg -q 'core/tests/a.xsh::t_improved' "$account_root/regressed.log"
mkdir -p "$account_root/empty"
: > "$account_root/empty/interrupted.txt"
: > "$account_root/empty/1.console.log"
if bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/empty" > /dev/null 2>&1; then
    printf 'accounting accepted a log without results\n' >&2
    exit 1
fi
mkdir -p "$account_root/unknown"
: > "$account_root/unknown/interrupted.txt"
printf 'core/tests/z.xsh::t_other ... ok 1ms\n' > "$account_root/unknown/1.console.log"
if bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/unknown" > /dev/null 2>&1; then
    printf 'accounting accepted a result for an undiscovered case\n' >&2
    exit 1
fi
mkdir -p "$account_root/interrupted"
printf 'core/tests/b.xsh\n' > "$account_root/interrupted/interrupted.txt"
printf '%s\n' 'core/tests/a.xsh::t_stable ... ok 1ms' 'core/tests/b.xsh::t_in_flight ... FAILED 1ms' > "$account_root/interrupted/1.console.log"
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/interrupted" > /dev/null
[[ "$(jaq -c '[.failed, (.unexecuted | length)]' "$account_root/interrupted/accounting.json")" == '[[],4]' ]]
mkdir -p "$account_root/interrupted-exact"
printf 'core/tests/b.xsh::t_in_flight\n' > "$account_root/interrupted-exact/interrupted.txt"
printf '%s\n' \
    'core/tests/a.xsh::t_stable ... ok 1ms' \
    'core/tests/b.xsh::t_in_flight ... ok 1ms' \
    'core/tests/b.xsh::t_late ... ok 1ms' > "$account_root/interrupted-exact/1.console.log"
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/interrupted-exact" > /dev/null
[[ "$(jaq -c '[.passed, .failed, (.unexecuted | length)]' "$account_root/interrupted-exact/accounting.json")" == '[["core/tests/a.xsh::t_stable","core/tests/b.xsh::t_late"],[],3]' ]]
mkdir -p "$account_root/cancelled-timeout"
: > "$account_root/cancelled-timeout/interrupted.txt"
printf '%s\n' \
    'core/tests/a.xsh::t_stable ... ok 1ms' \
    '---- core/tests/b.xsh::t_in_flight ----' \
    'TIMEOUT after 2m' \
    'test did not produce a result during bounded cancellation' \
    > "$account_root/cancelled-timeout/1.console.log"
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/cancelled-timeout" > /dev/null
[[ "$(jaq -c '[.failed, (.unexecuted | length)]' "$account_root/cancelled-timeout/accounting.json")" == '[["core/tests/b.xsh::t_in_flight"],3]' ]]
printf 'core/tests/b.xsh::t_in_flight ... ok 1ms\n' >> "$account_root/cancelled-timeout/1.console.log"
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/cancelled-timeout" > /dev/null
[[ "$(jaq -c '[.passed, .failed, (.unexecuted | length)]' "$account_root/cancelled-timeout/accounting.json")" == '[["core/tests/a.xsh::t_stable","core/tests/b.xsh::t_in_flight"],[],3]' ]]
printf '%s\n' \
    '---- core/tests/b.xsh::t_in_flight ----' \
    'TIMEOUT after 2m' \
    'test did not produce a result during bounded cancellation' \
    >> "$account_root/cancelled-timeout/1.console.log"
bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/cancelled-timeout" > /dev/null
[[ "$(jaq -c '.failed' "$account_root/cancelled-timeout/accounting.json")" == '["core/tests/b.xsh::t_in_flight"]' ]]
printf '%s\n' \
    '---- core/tests/z.xsh::t_other ----' \
    'TIMEOUT after 2m' \
    'test did not produce a result during bounded cancellation' \
    >> "$account_root/cancelled-timeout/1.console.log"
if bash "$repo_root/infra/asterinas/account-native.sh" "$account_root/discovered.json" "$account_root/cancelled-timeout" > /dev/null 2>&1; then
    printf 'accounting accepted a timed-out undiscovered case\n' >&2
    exit 1
fi
printf 'Asterinas native accounting checks passed.\n'
