# Performance

Methodology and the Charter thresholds. Absolute numbers are logged for the
record; only egregious regressions gate the run. The host during this
campaign is busy (load ~50 on 32 cores), so spreads are wide and
quiet-host confirmation stays open. See [local verification](testing.md)
for the test boundary and the [divergence register](divergence.md) for
behavioral deltas that perf does not move.

Run `tools/measure-perf.sh`. It builds the Rust release binaries, then:

- Coldplug: 6 runs on a synthetic tree (3 subsystems, 100 devices each,
  300 `uevent` files on tmpfs). Reports each run, median, and min-max
  spread. Timing is logged, not gated.
- Engine storm: `cargo bench --bench storm` warms 10k events, then measures
  10k more for `VmRSS` growth and `/proc/self/fd` delta. Gates only growth
  `>5%` and delta `!= 0`. The adapter under test reuses one `FakeOps`,
  like the daemon reuses one `RealOps`.
- Microbenchmarks: `cargo bench --bench parse` (Laputa config) and
  `--bench handle` (single `sda` event) are logged, not gated.
- Idle: the daemon starts with `-I 1`, signals readiness via `-D`, sleeps
  3 seconds; its `utime + stime` ticks from `/proc/<pid>/stat` must read
  zero. Gates on any nonzero tick count.

## Representative run (busy host, 2026-10-28)

Coldplug (microseconds, 300 files, Rust only):

- Rust: median ~17.9 ms, spread ~16.3-57.5 ms

Engine storm:

- `rss_before=644kB rss_after=644kB growth=0.00%` (gate `>5%` fails)
- `fds_before=4 fds_after=4` (gate `!= 0` fails)

Microbenchmarks:

- `bench_parse_laputa`: ~670 us per iteration
- `bench_handle_sda`: ~3.7 us per iteration

Idle (3 seconds):

- `rust_cpu_ticks=0` (gate: must read zero)

Result: `measure-perf: OK`. No threshold tripped. The wide coldplug spread
tracks host load, not the implementation.
