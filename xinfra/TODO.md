# TODO

Prefix: XIN
Next: 10

### XIN-9 · P3 · CLI remote apply is not covered by the integration suite

- **Area:** Testing
- **Where:** `dev/integration/example.xsh:180`, `dev/integration/multi_host.xsh:49`, `lib/xinfra/cli.xsh:1487`
- **Problem:** Integration cases exercise the resource layer and scheduler directly. `run_apply` (session reuse, lock, `--jobs`, notification folding) is covered only by `make perf` and manual runs, so a regression in the CLI remote path can pass `make integration`.
- **Recommendation:** Add a CLI apply case with two hosts and a slow command, asserting `--jobs 2` completes before `--jobs 1` and that the report has one row per action. Pass the XSH binary through `XINFRA_XSH` or a fixture-derived path.
- **Fix with:** `none`
- **Effort:** M

