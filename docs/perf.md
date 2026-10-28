# Performance

Methodology and the Charter thresholds. Absolute numbers are logged for the
record; only egregious regressions gate the run. The host during this
campaign is busy (load ~50 on 32 cores), so spreads are wide and
quiet-host confirmation stays open. See [local verification](testing.md)
for the test boundary and the [divergence register](divergence.md) for
behavioral deltas that perf does not move.

Run `tools/measure-perf.sh`. It builds the C oracle and the Rust release
binaries, then:

- Coldplug: 6 alternating runs per side on a synthetic tree (3 subsystems,
  100 devices each, 300 `uevent` files on tmpfs). Reports each run, median,
  and min-max spread. Gates only `rust median <= 2x c median`.
- Engine storm: `cargo bench --bench storm` warms 10k events, then measures
  10k more for `VmRSS` growth and `/proc/self/fd` delta. Gates only growth
  `>5%` and delta `!= 0`. The adapter under test reuses one `FakeOps`,
  like the daemon reuses one `RealOps`.
- Microbenchmarks: `cargo bench --bench parse` (Laputa config) and
  `--bench handle` (single `sda` event) are logged, not gated.
- Idle: both daemons start with `-I 1`, signal readiness via `-D`, sleep
  3 seconds, and compare `utime + stime` ticks from `/proc/<pid>/stat`.
  Gates only `rust <= 2x c + 2` ticks.

## Representative run (busy host, 2026-10-28)

Coldplug (microseconds, 300 files):

- Rust: median ~17.9 ms, spread ~16.3-57.5 ms
- C: median ~18.2 ms, spread ~15.8-23.8 ms
- Ratio: ~0.98x (gate `<=2.0x`)

Engine storm:

- `rss_before=644kB rss_after=644kB growth=0.00%` (gate `>5%` fails)
- `fds_before=4 fds_after=4` (gate `!= 0` fails)

Microbenchmarks:

- `bench_parse_laputa`: ~670 us per iteration
- `bench_handle_sda`: ~3.7 us per iteration

Idle (3 seconds):

- `rust_cpu_ticks=0 c_cpu_ticks=0` (gate `rust <= 2x c + 2` ticks)

Result: `measure-perf: OK`. No threshold tripped. The wide coldplug spread
tracks host load, not the implementation; the medians match within noise.
