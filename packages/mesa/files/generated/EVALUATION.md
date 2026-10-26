# Parser generation evaluation

Retain vendored parser and lexer outputs. The current XSH m4 produces the
expected perf outputs, but the supplied verification executable takes tens of
seconds per parser grammar in the measured host workflow.
Adding GNU m4 would add a runtime dependency to bison and flex. This evaluation
keeps the existing dependency closure and all Python-generated Mesa inputs.

The 2026-10-26 experiment used the checksum-pinned Linux 7.2.9 perf grammars,
Laputa `4af76649b9f3`, and the package's XSH m4 implementation, package release 11.
It ran on Linux x86_64 with the supplied XSH verification snapshot, host
bison 3.8.2, flex 2.6.4, and GNU m4 1.4.21 as the reference.
The interpreter used XSH `7261b0420` plus the user's uncommitted
optional-condition verifier fix in `producers.rs` and its two test files.
Its verification profile used optimization level 3 without LTO.
Each tool ran once per sample from an otherwise identical directory.
The only changed generator setting was `M4`.

Five samples per implementation alternated GNU m4 and XSH m4 for each workload.
Every sample passed `perf-gate-ready` immediately before generation and
`perf-gate-ready -1` immediately afterward. Every generated C file and header
was byte-identical to the checked-in perf output. The accepted set contains
30 generator runs and 60 file comparisons.
An earlier parse-events probe timed out under a 45-second limit and was
discarded with its preliminary GNU sample. No failed or timed-out probe
contributes to the table. Elapsed and CPU times include the generator and
its child processes. Peak RSS is GNU time's maximum resident-set statistic,
not the sum of concurrently resident processes.

| Workload | m4 | Median elapsed (range), seconds | Median CPU (range), seconds | Peak RSS range, KiB |
|---|---|---|---|---|
| perf expr parser, 391 lines | GNU | 0.05 (0.05–0.05) | 0.04 (0.04–0.05) | 1,316–1,580 |
| perf expr parser | XSH | 40.42 (39.87–43.74) | 40.35 (39.80–43.66) | 77,464–78,080 |
| perf parse-events parser, 647 lines | GNU | 0.06 (0.06–0.06) | 0.05 (0.05–0.06) | 1,316–1,568 |
| perf parse-events parser | XSH | 45.95 (44.67–46.70) | 45.88 (44.59–46.61) | 77,564–77,960 |
| perf expr lexer | GNU | below 0.01 | below 0.01 | 1,092–1,324 |
| perf expr lexer | XSH | 1.33 (1.25–1.35) | 1.40 (1.33–1.42) | 77,432–77,972 |

The XSH parser runs spend almost all elapsed time on CPU. Replacing only m4
removes nearly all of that cost, locating the bottleneck in m4 expansion.
The difference exceeds the observed spread. These figures measure generation,
including tool startup, rather than a package rebuild or a complete Mesa build.
They do not establish production release performance, Mesa grammar timing,
aarch64 performance, or throughput inside an isolated Laputa package root.

The measured XSH m4 source was 78,244 bytes. The reference GNU m4 executable is 231,552
bytes. The experiment's verification XSH executable is 47,584,360 bytes and is
already required by the distribution. These are individual file sizes, not
complete dependency-closure sizes. No binary, dependency, or payload changed.

The parser commands match the regeneration procedure in
[`perf/PKGBUILD.xsh`](../../../perf/PKGBUILD.xsh):

```sh
bison util/expr.y -d -o util/expr-bison.c -p expr_
bison util/parse-events.y -d -o util/parse-events-bison.c -p parse_events_
flex -o util/expr-flex.c --header-file=util/expr-flex.h util/expr.l
```

`M4` selected either `/usr/bin/m4` or the unmodified package m4 source with
its interpreter line pointing at the verification XSH snapshot. GNU time wrapped
each command. Generation outputs were compared with `cmp` before accepting
the resource sample. Existing generated outputs remain the default until a
separate change demonstrates an acceptable generation cost for the chosen
build workflow.
