# AGENTS.md

Vendored from laputa-systems/gluon at ba818ba; make changes upstream, not here.

gluon is a Rust workspace implementing Meson- and Ninja-compatible build
tools (`meson`, `ninja`, `gluon-build` in `bins/`). Library crates live in
`crates/`; differential tests in `tests/`. Details:
[docs/architecture.md](docs/architecture.md),
[docs/decisions.md](docs/decisions.md), [docs/testing.md](docs/testing.md),
[docs/status.md](docs/status.md).
Open defects: [TODO.md](TODO.md).

Build: `cargo build --profile dist --locked`
Test and lint: `make test`, `make lint`
Parity gate: `tests/differential/run.sh` (empty ledger)
Benchmarks: `tests/benchmarks/run.sh` (needs `perf-gate-ready`)

## Verification

- Edit: `cargo test --profile dist --locked -p gluon-ninja --test incremental`
  checks Ninja CLI rebuild and dyndep behavior; its standalone cost is unmeasured.
- Change: `make test` runs harness controls and the workspace dist suite. The
  Ground warm run took 4.81 s; the empty-target run took 278.19 s under shared load.
- Scenario: `tests/differential/run.sh` compares the pinned tools and candidate
  artifacts, exits and no-op builds; cost is unmeasured. Consumer checks and
  benchmarks are separately invoked workloads.
- Scheduling: `incremental::clean_edge_does_not_hold_the_only_jobserver_token`
  checks clean and dirty work together;
  `incremental::keep_going_blocks_failed_edge_dependents` checks failed-edge
  dependent blocking.
- Dirty checking: `incremental::ordinary_inputs_rebuild_and_restat_stays_idle_after_observing_them`
  checks explicit, implicit, phony and order-only inputs and restat;
  `incremental::missing_dependency_record_rebuilds_the_output` checks missing
  dependency records.
- Depfiles: `incremental::recorded_header_changes_rebuild_the_output` checks
  persisted header dependencies; `state::depfile` tests cover parsing. Dyndep
  readiness and dry runs have incremental tests and differential fixtures.
- CLI exits: `tests/differential/test-ninja-observables.sh` checks failure and
  no-op status accounting; Meson `cli::tests` check test-command failures.
- Meson subset: differential fixtures compare setup and artifacts;
  `crates/meson/tests/configure_file.rs` checks failed `configure_file` inputs
  and commands.
- Crate unit tests and engine equivalence cover public Rust behavior and generated
  Ninja manifests. Install and introspection JSON have CLI and install fixtures.
- FFmpeg-build, Laputa and Play are [consumers](docs/testing.md#consumer-checks).
  The Meson and Ninja notices and `tests/upstream/PINS` record imported revisions.

Invariants:

- First-party Rust crates and tests inherit the workspace's unsafe-code prohibition.
- User builds run in `crates/ninja`. `crates/engine` must not depend on
  Meson semantics. Meson setup writes `build.ninja` and does not execute
  the typed graph.
- Parity is observable behavior (artifacts, command sets, rebuild behavior,
  exit codes), not text; `tests/differential/expected-fail` lists divergences
  one per line with a one-line cause, and a listed fixture that passes fails
  the run.
- Upstream versions and import SHAs are pinned in `tests/upstream/PINS`;
  do not bump without differential tests.
- Licenses stay permissive-only: MIT/Apache-2.0 texts with NOTICEs per
  crate; Muon is a specification source, never copied code.
