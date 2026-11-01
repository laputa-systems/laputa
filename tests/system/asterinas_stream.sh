#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
mkdir -p "$repo_root/.work/tmp"
work="$(mktemp -d "$repo_root/.work/tmp/asterinas-stream.XXXXXXXX")"
runner=""
cleanup() {
    if [[ -n "$runner" ]] && kill -0 "$runner" 2>/dev/null; then
        kill -TERM "$runner" 2>/dev/null || true
        wait "$runner" 2>/dev/null || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
cat > "$work/xsht" <<'XSH_TEST'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$STREAM_PID"
if [[ "$STREAM_MODE" == empty ]]; then
    printf 'running 0 tests\ntest result: ok. 0 passed; 0 failed; 0 skipped\n'
    exit 0
fi
printf 'running 1 tests\nexample::case ... ok\n'
case "$STREAM_MODE" in
    success) printf 'test result: ok. 1 passed; 0 failed; 0 skipped\n' ;;
    failure) printf 'test result: FAILED. 0 passed; 1 failed; 0 skipped\n'; exit 1 ;;
    wait) exec sleep 30 ;;
    *) exit 2 ;;
esac
XSH_TEST
chmod 755 "$work/xsht"
python3 - "$repo_root/guest/asterinas/viability/overlay/usr/lib/asterinas/boot-proof.xsh" "$work" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text().split('\nproc main()', 1)[0]
source = source.replace('/usr/bin/xsht', f'"{sys.argv[2]}/xsht"')
source += '''
proc main(root: Path) [process, env, error] {
  let result = try { stream_xsh_tests(root, "all")? }
  match result {
    Ok(passed) => { assert passed; eprint --flush "STREAM_SUCCESS" },
    Err(problem) => { eprint --flush "STREAM_FAILURE"; return Err(problem) },
  }
}
main(args[0] as Path)
'''
Path(sys.argv[2], 'run.xsh').write_text(source)
PY
export STREAM_PID="$work/child.pid"
STREAM_MODE=success xsh "$work/run.xsh" -- "$work" > "$work/success.log" 2>&1
rg -Fq 'example::case ... ok' "$work/success.log"
rg -Fq STREAM_SUCCESS "$work/success.log"
if STREAM_MODE=failure xsh "$work/run.xsh" -- "$work" > "$work/failure.log" 2>&1; then
    printf 'stream accepted a failing test process\n' >&2
    exit 1
fi
rg -Fq 'example::case ... ok' "$work/failure.log"
rg -Fq STREAM_FAILURE "$work/failure.log" || { cat "$work/failure.log" >&2; exit 1; }
if STREAM_MODE=empty xsh "$work/run.xsh" -- "$work" > "$work/empty.log" 2>&1; then
    printf 'stream accepted an empty test selection\n' >&2
    exit 1
fi
STREAM_MODE=wait xsh "$work/run.xsh" -- "$work" > "$work/cancel.log" 2>&1 &
runner=$!
for _ in {1..100}; do
    rg -Fq 'example::case ... ok' "$work/cancel.log" 2>/dev/null && break
    sleep 0.05
done
rg -Fq 'example::case ... ok' "$work/cancel.log"
child="$(cat "$STREAM_PID")"
kill -TERM "$runner"
wait "$runner" || true
runner=""
if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    printf 'cancelled stream left its test process running\n' >&2
    exit 1
fi
printf 'Asterinas test output streams through failure and cancellation.\n'
