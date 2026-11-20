# Testing

The differential harness resolves Meson and Ninja from `PATH` once and
checks their versions against [`tests/upstream/PINS`](../tests/upstream/PINS).
It rejects executables that match the gluon candidates and stops if the
reference setup reports `oxidized-meson`. Put the pinned upstream tools
first on `PATH` before running the corpus.

For successful Ninja fixtures, the harness compares file contents. After
each successful Meson or Ninja build, the second Ninja invocation must
exit successfully without executing an edge. `make test-ci` exercises
the file and idle checks with injected failures.
For linked binaries and archives compared by symbols, the harness reads
defined global symbols in portable `nm` format. Archive member headings
are ignored, and an extraction error fails the fixture.

The expected-fail ledger (`tests/differential/expected-fail`) lists
fixtures known to diverge, one per line with a one-line cause. The harness
fails on any unlisted mismatch and on any listed fixture that now passes.
The ledger is empty. Setup and build must exit zero on both sides unless
the fixture declares the expected status in `setup-exit` or `build-exit`.
Intentional failure fixtures cover a missing install script, a missing
Ninja input and an absent dyndep file after its producer completes.

A Ninja fixture can name a target in `prepare-target`. Both engines build
it before the default build so the fixture can exercise incremental state.

Meson fixtures with `requires-pkg-config` are reported as skipped when
their listed dependencies are unavailable. For a full run, provide zlib,
wayland-client, wayland-protocols and the Wayland scanner. The Alpine
3.24.2 run used `zlib-dev`, `wayland-dev` and `wayland-protocols`.
Check `.work/tmp/diff/results.log` for skips before recording full
coverage.

The macOS CI job builds both release binaries and runs
`bash tests/differential/run-macos.sh`. The script verifies the pinned
Meson wheel and upstream Ninja archive before using them. It accepts a
skip only for the two Wayland fixtures. For a local run, use Python 3.10
or newer and build the binaries with
`cargo build --release --locked -p gluon-meson -p gluon-ninja`.

Gates, narrowest first:

- `cargo test --workspace` — unit/integration suites for all crates.
- `tests/differential/run.sh` — the fixture corpus; exit 0 only with the
  ledger honored.
- `tests/install/run.sh` — focused install fixtures (versioned shared
  library, an executable linked against it, headers in a subdir, pkgconfig)
  installed with reference Meson and with gluon; installed trees and
  RPATH/RUNPATH must match, without rpath, with `install_rpath` and with a
  build-only `build_rpath`.
- Use the [release workflow](../.github/workflows/release.yml) build command
  to verify static Linux musl artifacts on either architecture.
  `tests/upstream/musl.sh` checks only x86-64 binary invocation.
- Rustybench harnesses in `crates/*/benches` measure parse and plan work.
  The CLI benchmark checks commands and artifacts, including paired libdrm
  builds. See [benchmarks](benchmarks.md) for its oracle, timing gates and
  anchor capture procedure.

## Consumer checks

- FFmpeg-build's `build_dav1d` builds and installs the locked archive through
  Meson and Ninja. Verify the installed library with a linked decoder check.
- Laputa's `packages/gluon/proof.xsh` covers shell-free setup, build and
  installation.
- Build Play's pinned libplacebo and SPIRV-Cross against the candidate tools
  in an isolated checkout, then link the player crates against the dependency
  prefix. [Play's dependency build](https://github.com/joshuarli/play/blob/bae10f91b7003e208964eab030ba024d9b6c1a49/scripts/build-deps.sh)
