Prefix: DSLP
Next: 26

Deslop campaign backlog ([plan](https://github.com/laputa-systems/stuff/blob/main/docs/campaigns/deslop.md), tier B). One agent works this file with the `deslop` skill: take the lowest-numbered open ticket whose area does not start with `Needs owner ·`. After DSLP-5, work the open P1 and P2 findings, then fill in `## Report` below.

## Report

DSLP-1 named base `5d2169d1786659ec9da3d5f664c3a37df7d44405`; Ground
measured `2a1bca45da57bc36da9a60e1666bd392c9fe011f` on macOS ARM64
with nightly 2026-11-09. The deslop-labeled PRs from #10 through #53
are merged. Open tickets DSLP-16, DSLP-17, DSLP-18, DSLP-21,
DSLP-22, DSLP-23 and DSLP-25 are P3. DSLP-21 needs an owner decision
on the public dependency-log API. No P1 or P2 tickets remain open.

**Scorecard**

The figures below come from the step records retained in this section,
except where a different source is named. They describe the recorded
revisions and workloads, not a new full-campaign measurement.

| Measure | Before | After / disposition |
| --- | --- | --- |
| Rust lines in source and tests | `git ls-tree` and `git show` at DSLP-1: 31,974 physical lines in paths containing `/src/` and 40 in Rust test paths. | At `4300e0c5`, the same command counted 32,443 source and 830 test-path lines. Source counts include inline tests and comments. |
| Warm `make test` | Ground: 4.81 s. | Tests step: 16.44 s after, 15.84 s before its test change. Busy-host observations; not a timing gate. |
| Coverage | Tests step: 31.37% lines, 20.96% branches. | 31.52% lines, 21.19% branches; excludes the shell differential corpus. |
| Bounded mutation trial | One `mark_depfile_dirty` comparison mutant survived. | Caught after the header rebuild assertion. Completed trials had no timeouts or unviable mutants; approximately 340 aggregate runner-seconds includes a failed baseline attempt. |
| Escape hatches | Nine unsafe-code diagnostics in jobserver tests. Types census found 373 `unwrap_used`, 47 truncation and 23 sign-loss diagnostic sites, including tests. | Unsafe code forbidden across the workspace. The other counts are a census, not before-and-after counts. Total `allow`, unwrap and cast changes: Not measured. |
| Dead code | Unused direct `regex-lite` dependency and five unnecessary suppressions. | Dependency and suppressions removed; 16 declarations narrowed. Public recompaction API decision remains DSLP-21. |
| Findings | Diagnose filed DSLP-11 through DSLP-20. | P1 and P2 findings closed; the seven P3 tickets above remain. |
| Performance | 100,000 clean edges: 5,732.21 ms median in the paired scheduler comparison. | 292.98 ms median on the candidate; five pairs, qualified readiness, matching output and logs. Broader representative journeys and attribution remain DSLP-22 and DSLP-23. |
| Escaped regressions | Not measured. | Not measured. The bounded mutation survivor was a test gap, not a count of escaped regressions. |

The tests now protect recorded-header rebuilds and idle repeats, failed-edge
dependent blocking, missing dependency records, failed `configure_file`
operations, and other boundaries recorded in [Verification](AGENTS.md#verification).
That section predates the fixes for DSLP-12 through DSLP-14 and still calls
those three cases unprotected.
Differential fixtures check artifacts, exit status and idle builds against
pinned tools; consumer checks remain separate.

**Steps and cost**

- Seed: #10. DSLP-1 through DSLP-5 were established; cost not measured.
- Ground: #20. The empty-target suite took 278.19 s, the warm repeat
  4.81 s, and Clippy 291.12 s under shared load.
- Diagnose: #35 and #36. Dry-run readiness and reproduced findings were
  recorded; total review cost not measured.
- Types: #37, #38 and #40. Restat observations became typed and the
  workspace forbids unsafe code; total cost not measured.
- Tests: #43. Coverage and the bounded mutation trial are above; total
  step cost not measured.
- Dead code: #44. The dependency and suppressions were removed; total
  step cost not measured.
- Bench audit and entrypoint: #45. Edit controls took 0.65 s; the engine
  Change workload took 129.84 s cold and 8.44 s warm on a busy host.
- Findings: #46 DSLP-11, #47 DSLP-12, #48 DSLP-14, #49 DSLP-13,
  #50 DSLP-15, #51 DSLP-20, #52 DSLP-19 and #53 DSLP-24. Total fix
  cost not measured.

Verification gaps: no full suite or benchmarks were run for this report.
The installed `~/.local/bin/meson` and `~/.local/bin/ninja` are stale Gluon
releases; tests must not depend on an external `meson` from that location.
The mirror did not provide the mutation and coverage tools, and the broad
performance corpus lacks verified representative journeys and attribution.
The detailed records below preserve platform, consumer and fixture limits.

Bench audit (2026-11-19): the Rustybench engine queue, graph interning and
lookup, state logs/depfiles/snapshots, Meson lexer/parser and Ninja
manifest/planner/expansion/hash workloads are synthetic component probes,
with assertions of varying strength and 3–10 samples. They do not establish
end-to-end setup, reconfigure, no-op, source/header rebuild, consumer
throughput, artifact size or workload-tree CPU, memory and I/O outcomes.
The CLI corpus attempts setup and dry-run graphs plus source/header edits,
but its header is not a dependency and it does not compute the claimed
median. The corpus now checks command failures, artifacts and command counts.
Its RSS scope differs by time backend, and CPU is not reported. The corpus
has no accepted-revision anchor or verified cleanup; its release binaries
and references may be stale.

Ranked gaps: DSLP-22 (P3, missing representative correctness-checked
journeys and resource evidence) first; DSLP-23 (P3, missing attribution)
second. CPU sampling with child
processes, allocator profiling and syscall/I/O tracing in separate runs are
the cheapest attribution starting points; their scope and overhead need
measurement. No performance regression is claimed. PR #39 supplies proposed
work witnesses and PR #41 tests dependency recovery; both remain parked for
readiness-qualified timing. The driver permits the corpus after its failure
and work checks. Details and commands are in docs/benchmarks.md.
The Edit controls took 0.65 s. The engine Change workload completed in
129.84 s with a cold benchmark build and 8.44 s warm on the busy host.
Its five samples and allocation report are diagnostic, not a timing gate.

The Tests audit mapped the critical contracts in `AGENTS.md`. The
dependency-log header rebuild test now checks initial and changed output
bytes and idle builds. On macOS ARM64 with cargo-mutants 27.1.0, the
single `mark_depfile_dirty` comparison mutant (`>` to `<`) survived before
the test and was caught afterwards: the output stayed `first` instead of
`second`. The first attempt failed its baseline because cargo-mutants applied
an integration-test selector to the Ninja library package; no mutant ran.
The failed attempt and before/after trials used approximately 340 aggregate
runner-seconds. There were no timeouts or unviable mutants in the completed
trials. The survivor was a test gap, now asserted; DSLP-12 through DSLP-14
retain separate known defects.

`make coverage` reports Rust workspace coverage without the shell differential
corpus: before the test, 31.37% lines and 20.96% branches; afterwards, 31.52%
and 21.19%. The warm suite took 15.84 s before and 16.44 s after on a busy
host; those observations are not a qualified timing gate. The configured
crate mirror returned 404 for cargo-mutants and cargo-llvm-cov, while a known
package resolved. A mutation CI lane is required only
where the tools are mirrored, so DSLP-4 closes without one; the mirror gap is a
shared stuff registry item, recorded under the campaign's shared-file gaps.

Ground at `2a1bca45da57bc36da9a60e1666bd392c9fe011f` used
macOS ARM64 and pinned nightly 2026-11-09. The default Make goal
remains lint. The new `make test` alias runs the locked dist suite
used by the existing PR job. The normal workflow also runs on main.

With `TMPDIR="$PWD/.work/tmp"`, `CARGO_BUILD_JOBS=2`, and an
isolated `CARGO_TARGET_DIR`, both `make test` runs passed 85
top-level cases and one filtered child case. The empty-target run
took 278.19 s and the repeat took 4.81 s. Clippy passed in 291.12 s.
These observations include shared host load and compiler caching.
Cargo reported existing warnings about the workspace edition and
the `glob` dependency.

The workspace has eight packages. Tracked Rust and Python files
contain 32,758 and 397 physical lines respectively, including
tests and comments. [Verification](AGENTS.md#verification)
records the owning boundaries and both fleet consumers. The
existing benchmark suite remains the workload for build hot paths.
Consumer, differential, install and release performance gates
remain separate work.

The differential harness review reproduced the self-comparison problem
from GLU-28. The installed gluon binaries declared the same versions as
upstream. With those binaries first on `PATH`, the prior harness accepted
them as its own references. The preflight now checks the pinned versions,
rejects matching binaries, and keeps the resolved reference paths for the
fixture run. `make test-ci` exercises the preflight fixtures.

The updated harness passed with Homebrew Meson 1.12.1 and Ninja 1.13.2
and the installed `release-fa8b6aa` candidate. Six cases still shared a
build or setup failure. Among them, `subninja` used a child-scoped rule
from the parent, both Wayland fixtures lacked dependencies, and
`llvm-config-tool` failed at link time. The full hosted parity gate and
remaining Diagnose review stay open.

The corrected `subninja` and `llvm-config-tool` fixtures both built with
the installed candidate and pinned upstream tools. The fixture harness
rejected matching failures when the parent used an undefined rule or
the macOS linker received the old `--defsym` flags. Both LLVM products
exported the required module, static link, and system-library markers.
In the full repeat, four fixtures still shared failures. Two required
unavailable Wayland dependencies, and the other two were the intentional
missing install script and missing Ninja dependency cases.

The harness now rejects changed Ninja output bytes, commands during the
idle repeat, and failed idle exits. The shell regression runs each fault
through the fixture runner. Archive symbol comparison ignores member
headings and rejects an `nm` failure even after partial output. The
symbol regression passed with both Apple and GNU `nm`.

The 55-fixture run used the `release-fa8b6aa` binaries and upstream Meson
1.12.1 and Ninja 1.13.2 on macOS ARM64 and Alpine 3.24.2 ARM64. The Linux
Ninja was built from upstream `3441b633`; the PyPI Ninja wheel identifies
itself as a modified build and was rejected. Both Wayland fixtures linked
on Alpine with wayland-dev 1.25.0-r0 and wayland-protocols 1.48-r0.
On macOS those two cases shared missing-dependency exits. On Alpine
`generator-depends` shared a duplicate-symbol failure and
`pkgconfig-generate` shared a missing zlib failure. Both runs also
reported the intentional failing install-script and missing-dependency
fixtures. GLU-28 and the full hosted parity gate stay open.

The generator fixture now writes its declared `dep.txt` and defines its
generated C symbol in one translation unit. On macOS ARM64 and Alpine
3.24.2 ARM64 both binaries produced `dep.txt`, linked an executable
that returned zero, and ran no edges on the repeat build. The idle check
now applies to successful Meson fixtures too. With zlib-dev 1.4-r0 added,
the pkg-config fixture built on Alpine. The full Linux rerun had 53
successful builds and the two intentional failures. The macOS rerun had
51 successful builds, the two intentional failures, and two shared
Wayland setup failures caused by missing dependencies.

The runner now requires the expected stage exit status from each tool.
Only the missing install script and missing Ninja input declare a
nonzero exit. The shell regression rejects both an unexpected shared
failure and unexpected success in a failure fixture. Missing pkg-config
prerequisites are explicit skips. The Alpine rerun recorded 55 passes
including the two intentional failures, with zero skips. The macOS
rerun recorded 53 passes including the two intentional failures, and
skipped both Wayland fixtures because pkg-config could not resolve their
dependencies.

The macOS CI runner now builds the candidate and uses the checksum-pinned
Meson wheel and upstream Ninja archive. A local ARM64 run with freshly
built candidates and Python 3.14.8 passed 53 fixtures, including two
intentional failure cases, and skipped the two optional Wayland cases.
A changed wheel checksum stopped the runner before installation. The
hosted workflow pins Python 3.14.10 and rejects any other skipped fixture.

Declared-input validation now runs before dry runs or command dispatch.
Pinned Ninja and the candidate rejected four kinds of missing input in
normal and dry runs, and both still built an unrelated selected target.
Deleting a header listed in a stale depfile still triggered its rebuild.
The differential fixture for a dyndep-generated input verifies the
producer and consumer outputs. Meson now declares the force target its
install rule uses. Reconfiguring a build tree from `release-fa8b6aa`
restored its install with the original setup options.

The macOS corpus passed 54 fixtures and skipped the two Wayland cases.
Both rebuilt static ARM64 binaries passed ELF verification under the
pinned musl toolchain. Alpine 3.24.2 ran all 56 fixtures with zero skips
including the two intentional failures. The time-based performance
gate is deferred because `perf-gate-ready` reported a hot OrbStack
process tree. DSLP-7 through DSLP-9 retain the separate incremental
and generated-metadata failures reproduced on the prior release.

The clean dyndep fixture primes two metadata producers before building
the defaults. The old scheduler returned zero with four files missing.
The candidate produced matching primary, generated, output and separate
files with Ninja 1.13.2, then stayed idle. A phony producer that left
its declared metadata absent returned exit one and produced no consumer
output. The macOS corpus passed 56 fixtures with two Wayland skips.
Stable Alpine passed all 58 with zero skips. Both counts include three
intentional failures.

The incremental CLI regression updates an explicit source, an implicit
source and a source reached through a phony edge. Those outputs now
refresh. An order-only consumer keeps its original bytes. The restat
rule runs once for a newer input and keeps its downstream output quiet.
Pinned Ninja and the candidate passed the regression. The previous
release kept the old bytes for the explicit input.

The build log retains its v6 layout. Restat records can use command
start as their timestamp when output mtime alone would cause repeated
rebuilds. An actual log from `release-fa8b6aa` survived a failed
command byte for byte. The next successful invocation rebuilt once,
and the following invocation was idle. The macOS corpus passed 56
fixtures with two Wayland skips. The Alpine corpus passed all 58.
The incremental test also passed in the pinned ARM64 musl toolchain.

The warm Ninja comparison alternated six pairs of release binaries
from `2a13e76` and `f883c86` on macOS ARM64. Separate Cargo targets
produced distinct binaries. Each size used the same warmed directory
for both commands with `-j2`. Input and output files existed for every
edge. Both readiness checks exited zero, and all output bytes and build
logs matched their pre-run snapshots.

At 1,000 edges, median wall time went from 14.7 ms to 15.0 ms with
ranges of 14.0–15.3 ms and 14.3–15.8 ms. At 10,000 edges the medians
were 137.0 ms and 139.0 ms with ranges of 131.6–143.3 ms and
138.7–140.6 ms. Median child CPU time at that size was 129.3 ms and
131.8 ms. The differences fall within the observed spread. The
broader performance corpus remains open.

Generated dyndep files enter planning only when their producers and
prerequisites are ready. The CLI controls preserve the old metadata
bytes on rejection when a generator command changes, when a transitive
input becomes newer and when a nested metadata entry declares the
dirty prerequisite. The checks exercise normal and dry runs. An
up-to-date generator with no build log is usable, and the same
generator flag protects its file from ordinary cleaning. The graph
JSON control confirmed that it reports the same flag.

All five CLI controls passed against pinned Ninja and the candidate.
The rebuilt ARM64 Linux binaries passed static ELF verification.
Alpine passed all 58 fixtures, and macOS passed 56 with the two
Wayland skips. Both fixture counts include three expected failures.

Ninja dry runs now use the same readiness decisions as an executing
build. The CLI regressions cover clean and dirty outputs, descriptions
and verbose commands, quiet mode, response files, manifest regeneration
and a generated dyndep file that does not yet exist. They pass on
macOS ARM64 and ARM64 musl. The full differential corpus passed 56
fixtures on macOS with two Wayland skips and all 58 on stable Alpine,
including three expected failures on each platform. On a graph with
100,000 cold edges, a dry run emitted the same 100,000 lines as pinned
Ninja 1.13.2. Both directories still had no outputs or build logs.

The scheduler now visits only each completed edge's direct dependents.
On macOS ARM64, separate `cargo build --profile dist --locked -p
gluon-ninja` targets built base `2785395` and candidate `7b24618`.
Each warm comparison used the same directory for both sides, with one
shared source, one `cp` output per edge, and matching v6 command log
records. Both readiness checks exited zero. Each row alternated order
over five pairs with `-j2`. Output bytes and the log hash stayed the
same across all no-op invocations. Source and header rows used separate
warmed trees for each invocation. A `cc -MMD` depfile tracked the
header. Each edited tree recompiled once and the program's exit status
changed from zero to seven.

| Workload | Base median wall, ms (range) | Candidate median wall, ms (range) |
| --- | ---: | ---: |
| 1,000 clean edges | 10.41 (9.97–12.32) | 9.43 (9.17–11.78) |
| 10,000 clean edges | 90.31 (88.10–93.67) | 36.38 (35.75–40.87) |
| 100,000 clean edges | 5,732.21 (5,482.44–5,867.77) | 292.98 (287.59–308.76) |
| One source rebuild | 66.75 (65.35–77.30) | 70.09 (65.37–81.03) |
| One header rebuild | 60.79 (58.07–62.82) | 61.56 (54.19–65.13) |

At 100,000 edges, median child CPU time was 5,690.54 ms and 281.44 ms.
Peak RSS for the separate memory check was about 117.4 MiB on both
sides. The stripped Ninja binary grew by 16 bytes. Source and header
differences fall within the run-to-run ranges. Meson timing remains
open. The existing benchmark script's dry-run count can accept
different work and mask command failures. The Tests step must make
that entry point verify equivalent work before using its timings.

FFmpeg-build at `b9d9ce52` ran its actual `build_dav1d` entry point
using the checksum-locked dav1d 1.5.4 archive, upstream Meson and a
`PATH` override that traced the pinned reference and candidate Ninja
binaries in separate build and install trees. Installed headers,
ordered archive member names and every object hash matched. A program
linked to each archive opened and closed a decoder and printed 1.5.4.
Laputa's package proof fixture from `3bbdd993` ran its setup, build
and install commands with `GLUON_SHELL=forbid` on Alpine 3.24.2
ARM64. `PATH` resolved both commands to the static `dist` binaries
built from `7b24618`. The warm preview reported no work, and the
installed version and notes matched the fixture bytes. This covers
the downstream command and artifact checks. Laputa's package manager
and dynamic-loader checks were outside that fixture run.

The Rust profile census found nine unsafe-code diagnostics, all
from the jobserver tests. The tests now pass flags directly to the
parser or set them on a child Ninja process. FIFO creation uses
`mkfifo`. The child test preserves the check that an existing clean
edge leaves the implicit jobserver slot available to a dirty edge.
The workspace forbids unsafe code and all eight packages inherit
the lint. An injected unsafe block in a copy of the graph crate
failed `cargo check --locked -p graph` at the block.

The two Ninja packages passed 34 dist-profile tests on both macOS ARM64
and ARM64 musl. The Linux run used the pinned image's
`MUSL_BUILD_MODE=test` and prebuilt target standard library.
The pinned ty and Ruff checks passed over the Python test helpers and
fixtures. The fleet rule resolves workspace inheritance and checks all
eight Gluon packages on the merged default revision.
[Fleet rule](https://github.com/laputa-systems/stuff/pull/167) ·
[Profile registration](https://github.com/laputa-systems/stuff/pull/168)

The Types census ran `cargo clippy --locked --workspace --all-targets`
with each candidate at warning level, using JSON diagnostics and
counting unique primary file and line sites. The counts include tests.
The following candidates were left out of the workspace profile.

| Candidate | Sites | Reason |
| --- | ---: | --- |
| `cast_possible_truncation` | 47 | The blanket rule flags bounded string slice cursors and width-specific ELF encoding. |
| `cast_sign_loss` | 23 | The same ELF encoder writes the bit representation of signed tags. Slice cursors clamp at zero before casting. |
| `expect_used` | 7 | Six sites are fixture assertions. The only production site reads the executable path, which belongs with the existing integrated-invocation finding. |
| `unwrap_used` | 373 | Test assertions and infallible writes into the backend's `String` account for many sites. |
| `needless_pass_by_value` | 10 | Diagnostics include the public `Cli::parse_args_from` signature. The sampled sites did not demonstrate a correctness failure. |
| `redundant_clone` | 27 | Sampled sites suggest allocation cleanup, with no demonstrated type or ownership defect. |
| `wildcard_enum_match_arm` | 145 | The backend deliberately maps unhandled object variants to no target path. |
| `match_wildcard_for_single_variants` | 0 | No witness. |

The Diagnose review at `32f2ef4` covered Ninja dispatch and state,
Meson setup, generated commands, installation and introspection, and
the public entry points. The macOS dist suite passed 93 top-level tests
and one filtered child case. Clippy and the documentation check passed.
The review kept three existing boundaries visible: declared cycle
detection, command success before build-log recording, and a shared
install plan for execution and introspection.

The pinned Ninja comparison reproduced dependent dispatch after a
failed edge and a stale executable after dependency-log loss. The
failed-generator control left a newer output idle on both engines,
so it did not establish a parity defect. The pinned Meson comparison
reproduced setup errors accepted as success, lost machine-file options
and generated content replaced by raw input. The integrated CLI failed
to install a static library that the standalone CLI installed.

An isolated copy of the benchmark harness returned zero and printed
`benchmarks: PASS` when all 14 timed build tool invocations returned
seven. The review filed the failure as DSLP-11 and the runtime findings
as DSLP-12 through DSLP-20. It did not qualify the full build and
installation matrix or pursue owner-dependent work outside Gluon.

The first Types change pairs each output with its restat observation.
The old completion type accepted one output and zero timestamp entries.
An isolated compiler witness accepted that shape at `c5e681d`.
The new type rejects a bare output path with E0308. It distinguishes
an output observed missing before the run from a path for which the
scheduler did not take a timestamp. The dispatcher attaches this
record once for both ordinary and console commands.

Clippy and all eight dist-profile incremental tests passed on macOS.
Five interleaved dist pairs used two outputs from one restat rule.
Each tree began with two installed outputs and a warm no-op invocation.
Touching the source without changing its bytes ran the generator alone.
Replacing its bytes ran the generator and the two consumers. Both
engines produced the same bytes and then stayed idle. Median wall times
were 24.94 and 25.04 ms for the unchanged case and 26.91 and 26.61 ms
for the changed case. The ranges overlapped in both cases. Both host
readiness checks passed. The 100,000-edge warm graph kept its output
bytes and build-log hash. One baseline observation was much slower than
the rest, so that run establishes no speed difference. The stripped
Ninja binaries had the same size.

The candidate at `d2293f1` passed 56 differential fixtures on macOS
with the two Wayland skips and all 58 on stable Alpine ARM64. On
Alpine the reference was Ninja 1.13.2 built from its tagged source
`3441b63` and the checksum-pinned Meson 1.12.1 wheel. The static dist
binaries passed the Laputa install fixture. FFmpeg-build installed
the locked dav1d archive and the decoder check returned 1.5.4.
Play rebuilt SPIRV-Cross and libplacebo with the candidate Ninja,
linked `player-app`, and loaded the resulting libplacebo library
when started with `--version`.

The Dead code pass checked workspace targets on macOS ARM64 with the
pinned nightly and default features. Cargo-machete found `regex-lite`
unused by Meson: source, build registrations, manifests, tests, scripts
and docs contain no reference beyond that direct dependency. The Meson
entry points in `bins/meson` and `bins/build` use the Meson crate; the
Ninja binary, differential fixtures and downstream FFmpeg-build, Laputa
and Play consume the built commands, not this dependency. The declaration
was removed; `rustybench` still brings it into the lockfile. No behavior or
public API was removed. Consumer builds and the full differential corpus
were not rerun for this static change; `make test` exercises the harness
controls and workspace suite. Other platforms and feature combinations were
not run.

The compiler found 16 unreachable public declarations in private Ninja
modules. The dyndep parser and its types, binding lookups and jobserver
client are called by `build::runner`; the six tool functions are registered
in `tools::run`. Their visibility was restricted without removing them.
The scheduler calls `Options::jobs_count`; engine equivalence tests and Ninja
benchmarks call `manifest::parse`. Five unnecessary dead-code suppressions
were removed, including three on the public state dependency log API.
`close` and `recompact` have unit-test callers; `needs_recompaction` has no
reader. DSLP-21 records the owner decision for that exposed API. The
all-target compiler scan includes the test-only helpers: Meson's help test
calls `example_matches`, and Ninja help and tool tests call `example_args`.
No warning allowlist is needed.

The debloat review kept the public engine queue, used by its test and
benchmark, and the CLI, manifest, dependency-state and differential layers:
they expose APIs or preserve build and compatibility contracts. No proven
behavior-preserving structural cut beyond the dependency was identified.
Existing Findings tickets and the benchmark timing gates were left alone.

## Tickets




























### DSLP-16 · P3 · Ninja depfile parsing corrupts UTF-8 and escaped hashes

- **Area:** Ninja dependency paths
- **Where:** crates/state/src/depfile.rs:63,84
- **Problem:** Compile with cc -MMD and deps = gcc while including café.h or name#part.h. Both Gluon builds recompile on a warm invocation. Ninja 1.13.2 stays idle and recompiles after an actual edit. The parser converts UTF-8 a byte at a time and treats the escaped hash as a comment.
- **Recommendation:** Preserve path bytes and consume Make depfile escapes before interpreting comments. Check a warm no-op and a header edit.
- **Fix with:** reference-parity
- **Effort:** M


### DSLP-17 · P3 · Meson target introspection omits custom targets

- **Area:** Meson introspection
- **Where:** crates/meson/src/backend.rs:92,1741
- **Problem:** Declare custom_target('copy', output: 'data.out', command: [find_program('touch'), '@OUTPUT@']). Reference Meson includes copy in intro-targets.json. Gluon emits the Ninja target and returns an empty target array.
- **Recommendation:** Generate entries for supported custom targets using the owning build data. Compare ID, outputs and type to pinned Meson.
- **Fix with:** reference-parity
- **Effort:** M

### DSLP-18 · P3 · Meson setup silently accepts malformed option files

- **Area:** Meson option parsing
- **Where:** crates/meson/src/options.rs:392, crates/meson/src/builtins/functions.rs:427
- **Problem:** Use project('m') in meson.build and an unterminated option( in meson.options. Gluon setup exits zero. Meson 1.12.1 exits one and reports the unexpected end at meson.options:1:8.
- **Recommendation:** Surface read and syntax failures with file and position. Preserve optional and valid option files.
- **Fix with:** error-model
- **Effort:** S

### DSLP-21 · P3 · decide whether to retire unused deps log recompaction API

- **Area:** Needs owner · state public API
- **Where:** crates/state/src/deps_log.rs:46,248,256; crates/ninja/src/build/mod.rs:5
- **Problem:** The exported needs_recompaction field has no reader and remains false; recompact is called only by a unit test and close by that method and tests. Removing them changes the state crate API, also re-exported by ninja, and possible external consumers are unknown.
- **Recommendation:** Decide whether consumers may lose these members; if so remove them and the recompact-only test, preserving the supported on-disk format.
- **Fix with:** dead-code-archaeology
- **Effort:** S


### DSLP-22 · P3 · measure verified end-to-end build journeys

- **Area:** benchmark coverage
- **Where:** tests/benchmarks/run.sh:57-79; crates/ninja/benches/ninja.rs:23
- **Problem:** Component benchmarks use synthetic data and the CLI corpus lacks equivalent-work witnesses; no trusted workload covers real setup, reconfigure, no-op, source and header rebuilds or consumer-scale throughput and resource usage. Regressions in these journeys can escape measurement.
- **Recommendation:** After DSLP-11, add pinned representative consumer journeys with output and completed-work checks, paired baselines and scoped CPU, memory and I/O measurements.
- **Fix with:** refactor-benchmarks
- **Effort:** L

### DSLP-23 · P3 · add attribution for build performance regressions

- **Area:** benchmark observability
- **Where:** tests/benchmarks/run.sh:30-42; crates/engine/benches/engine.rs:2
- **Problem:** The suite reports elapsed time and limited process RSS or allocator counts but has no documented workload-tree CPU, allocation, I/O or trace attribution. A change in a benchmark cannot be localized reliably, and child peaks are not workload-tree peaks.
- **Recommendation:** Document separate diagnostic runs using platform CPU sampling, allocation profiling and syscall or I/O tracing with operation boundaries, including scope and overhead.
- **Fix with:** bench-pyramid
- **Effort:** M


### DSLP-25 · P3 · meson.build changes do not regenerate build.ninja

- **Area:** meson · backend
- **Where:** crates/meson/src/backend.rs regeneration edge
- **Problem:** The regeneration edge depends only on command-based configure_file inputs, so editing meson.build does not rerun setup on the next ninja invocation. Meson regenerates when any build definition file changes.
- **Recommendation:** Add the processed meson.build and meson_options files to the regeneration edge inputs and test that editing meson.build regenerates once and then idles.
- **Fix with:** reference-parity
- **Effort:** S

