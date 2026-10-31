# TODO

Prefix: XIN
Next: 10

### XIN-8 · P3 · Saved-plan artifacts have two schema implementations

- **Area:** Types
- **Where:** `lib/xinfra/plan_artifact.xsh:15`, `lib/xinfra/cli.xsh:82`, `dev/integration/plans.xsh:3`
- **Problem:** The CLI defines `PlanArtifact` and its save/load/stale checks in `cli.xsh`, while `plan_artifact.xsh` defines a second `Artifact` with different fields and is used only by the saved-plan integration case. The schemas can drift, and the CLI artifact is the one users see.
- **Recommendation:** Keep one artifact module, move the CLI save/load/stale checks onto it, and point the integration case at the same code.
- **Fix with:** `deduplicate`
- **Effort:** M

### XIN-9 · P3 · CLI remote apply is not covered by the integration suite

- **Area:** Testing
- **Where:** `dev/integration/example.xsh:180`, `dev/integration/multi_host.xsh:49`, `lib/xinfra/cli.xsh:1487`
- **Problem:** Integration cases exercise the resource layer and scheduler directly. `run_apply` (session reuse, lock, `--jobs`, notification folding) is covered only by `make perf` and manual runs, so a regression in the CLI remote path can pass `make integration`.
- **Recommendation:** Add a CLI apply case with two hosts and a slow command, asserting `--jobs 2` completes before `--jobs 1` and that the report has one row per action. Pass the XSH binary through `XINFRA_XSH` or a fixture-derived path.
- **Fix with:** `none`
- **Effort:** M

