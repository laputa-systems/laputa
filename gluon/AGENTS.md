# AGENTS.md

gluon is a Rust workspace implementing Meson- and Ninja-compatible build
tools (`meson`, `ninja`, `gluon-build` in `bins/`). Library crates live in
`crates/`; differential tests in `tests/`. Details:
[docs/architecture.md](docs/architecture.md),
[docs/decisions.md](docs/decisions.md), [docs/testing.md](docs/testing.md),
[docs/status.md](docs/status.md).
Open defects: [TODO.md](TODO.md).

Build: `cargo build --profile dist --locked`
Test: `cargo test --profile dist --locked`
Parity gate: `tests/differential/run.sh` (empty ledger)
Benchmarks: `tests/benchmarks/run.sh` (needs `perf-gate-ready`)

Invariants:

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
