# Benchmarks

`make bench-list` lists workloads, tiers, areas and commands. `make bench`
defaults to the Change ceiling. Set `BENCH_ARGS`, for example:

```
make bench-check BENCH_ARGS='--tier Change --name engine'
make bench BENCH_ARGS='--tier Change --area engine --dry-run'
make bench BENCH_ARGS='--tier Edit'
make bench BENCH_ARGS='--name engine --skip controls'
```

`--name` selects workload names; `--area` selects areas. Each can be repeated;
within each kind they are alternatives, while kinds intersect. `--skip` takes
names. Unknown values and empty selections fail. The dry run writes nothing.
Full is manual-only: explicitly request `--tier Full`; it includes the
Scenario corpus. The driver checks selected executables and disk space before
running anything. Cargo builds its own artifacts from the pinned toolchain and
lockfile. Component measurements are diagnostic and do not establish a gate.

| Workload | Tier / area | Purpose and requirements |
| --- | --- | --- |
| controls | Edit / harness | Selection, oracle and verdict tests; Python 3. |
| engine, graph, state, meson, ninja | Change / respective crate | Synthetic component measurements; Cargo. |
| cli-corpus | Scenario / cli | Setup, dry-run and rebuild corpus plus libdrm; pinned reference tools, compiler and release binaries. |
| all-components | Full / components | Entire Rustybench workspace; Cargo. |

Runs write logs and a summary under `.work/bench/<date-time>/`. The CLI corpus
checks command failures, artifacts and command counts. Its libdrm workload uses
the pinned 2.4.134 archive, verifies its SHA-256, and builds with Laputa's
libc-only configuration using both pinned reference Meson/Ninja and gluon. It
compares object and library output file sets and full-build, no-op and
one-source rebuild command counts. No-op must execute zero commands; full and
incremental builds must execute work. It measures cold setup, full build,
no-op and incremental rebuild, alternating runner order over three iterations,
and reports medians of qualified samples. Each measurement is bracketed by
`perf-gate-ready` and `perf-gate-ready -1`. A busy or overlapping run is
inconclusive; its timings are discarded. Run just this workload with:

```
python3 tests/benchmarks/libdrm.py
```

A committed `tests/benchmarks/libdrm-anchor.json` records the accepted gluon
median in seconds for each phase, fractional tolerance, commit, host and date.
A matching host and a qualified run yield `within budget` or `regression` by
comparing each median to its anchor plus tolerance. A missing or uncommitted
anchor, different host, or busy gate yields `inconclusive` with a reason.
Invalid committed anchors fail rather than passing. Capture on a quiet host
from a clean accepted revision, review the generated file and commit it:

```
python3 tests/benchmarks/libdrm.py --capture-anchor --tolerance 0.10
```

The capture refuses dirty worktrees and unqualified runs. No anchor is supplied
for a busy host. For diagnosis, run CPU sampling, allocation profiling or
syscall tracing separately from timed measurements; record their overhead and
process scope.
