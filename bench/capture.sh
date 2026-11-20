set -eu
: "${XSH_ROOT:?set XSH_ROOT}"
: "${ANCHOR_TOLERANCE_BYTES:?set ANCHOR_TOLERANCE_BYTES}"
[[ $ANCHOR_TOLERANCE_BYTES =~ ^[0-9]+$ ]]
mkdir -p .work/tmp
log=.work/tmp/bench-anchor-$$.log
perf-gate-ready >&2
make bench XSH_ROOT="$XSH_ROOT" TIER=scenario WORKLOADS='tree-memory artifact-sizes' > "$log"
perf-gate-ready -1 >&2
summary=$(awk '/^summary: / {print $2}' "$log")
[[ -f $summary ]]
run_dir=${summary%/*}
for status in "$run_dir"/*.ready-status; do
  [[ $(cat "$status") == '0 0' ]] || { echo 'anchor rejected: host busy during workload' >&2; exit 1; }
done
[[ -z $(git status --porcelain) ]] || { echo 'anchor rejected: dirty checkout' >&2; exit 1; }
commit=$(git rev-parse HEAD)
host=$(uname -n)
date=$(date -u +%Y-%m-%d)
awk -F '\t' -v tolerance="$ANCHOR_TOLERANCE_BYTES" -v commit="$commit" -v host="$host" -v date="$date" '$1 == "metric" {print $2 "\t" $3 "\t" tolerance "\t" commit "\t" host "\t" date}' "$summary"
