# Testing

Set up the host tools as described in [development](DEVELOPMENT.md#xsh-tools).
The examples below use its `XSHT` environment variable.

```bash
make check         # xsht check over the tree, plus shebang-only XSH scripts
make lint          # production PM, system, installer, and xinit modules
$XSHT lint         # the full configured tree, including recipes and tests
make test-pm
make test-system   # tests/system, then tests/integration
make test-xinit
make test-linux    # the kernel recipe's Kbuild tests and linux-headers' headers_install tests
make test          # all four
make test-components # Rust component suites, lint, and local harness tests
make test-components-integration # components, PM, and all three guest profiles
```

Kbuild planner tests cover object-list replacement, nested `patsubst` and
`foreach` expansion, conditional defaults for defined empty flags, and
`cc-option`/`cc-disable-warning` calls, which are probed with the target
compiler when archive tasks are planned. Planning fails on any compile
argument that still contains `$(`. These fixtures do not qualify a complete kernel build.

`xsht-config.ini` sets `module_path` to this checkout, so `xsht` resolves
`system.*`, `seed.*`, and PM imports, including `use` imports inside profiles
loaded through `module.load`. It excludes the fixture trees under
`tests/*/fixtures/` and `mirror/`. `make check` also checks the XSH programs
installed under other names (installer and profile boot hooks, baselayout's
`getent`), which xsht's `*.xsh` scan does not find; it finds them by their
`#!/bin/xsh` shebang.

Narrow before widening: `xsht check` on the changed modules, then the focused
suite (`$XSHT test tests/pm/pm_plan.xsh`), then the Docker builds, and QEMU
last. Run one suite at a time. `make test-pm-docker` runs the whole PM suite
inside package-tools with the seed, offline; `make test-pm-native` runs it
against `XSH_ROOT`'s debug build with coverage.

`tests/integration/cross_consumer.xsh` imports PM and the profile modules
together. Check and run it on its own to tell PM-owned diagnostics from
profile-owned ones:

```bash
$XSHT check tests/integration/cross_consumer.xsh
$XSHT test --jobs 1 tests/integration/cross_consumer.xsh
```

`make test-components` runs the retained host tests for mdevd, seatd, doas,
and tinyland, the documented Rust lints for the first three, mdevd's dependency
gate, and tinyland's QMP harness tests. Seatd's golden transcript is part of
its Cargo suite. Tinyland needs the native libxkbcommon development library
and XKB rules; set `TINYLAND_XKB_LIB_DIR` and `TINYLAND_XKB_ROOT` if those
are not under `/usr/lib` and `/usr/share/X11/xkb`. A prepared guest root can
also supply them. Linux musl host tests link libxkbcommon dynamically with mold.
This target does not build packages or boot guests.

`make test-components-integration` also runs Tinyland's package-lock test,
the PM suite, and the canonical dwl, tinyland, and VT-bound tinyland profile
tests in sequence. The package-lock test needs the cached Alpine minirootfs and
locked packages; prepare them as described in the [Tinyland verification guide](../tinyland/docs/verification.md).
The profiles need the infrastructure described in [QEMU](QEMU.md) and
[Tinyland](TINYLAND.md). This explicit integration gate is separate from
`make test` and `make verify`.

Use `cargo -j 4` for Rust checks. `make mirror-test` checks the mirror and its
POSIX deployment scripts; on Linux it runs Cargo offline in `xsh-test`.
`make verify` is the full host proof from a clean build, with logs and a timing
table under `.out/verify/`; reserve it for an explicit full verification run.

The aarch64 world rebuild and boot proofs are unverified; see [TODO](../TODO.md).

The standalone Linux x86_64 Docker authority check uses a local image with
an existing `/bin` and `/usr/lib/xsh/core`, plus a native static XSH seed
directory containing `xsh`, `xshi`, `xsht`, and `core/`:

```bash
TMPDIR="$PWD/.work/tmp" "$XSH_HOST" tests/docker/profile_network.xsh -- xsh-test:latest "$PWD/.out/seed/x86_64"
```

Create `.work/tmp` before running the check. The image is an explicit trusted
test substrate; the check does not fetch or build package-tools. A bridged
control must accept a UDP route lookup without sending packets. The profile
adapter must reject the same lookup with `ENETUNREACH` under `--network none`.
The check also verifies that host poison variables stay outside the container,
host sentinels survive, the checkout mount rejects writes, and `/output` remains
writable. It does not qualify C, Rust, or XSH package builds or a per-package
input closure. The default native suites do not require Docker for this check.

### Use the fixed xinit tool snapshot

The independent checks use frozen `bin/{xsh,xshi,xsht}` and matching `core/`
inputs. The supplied `xinit-optional-condition` verification build contains
XSH `7261b0420` plus the user's optional-condition verifier repair.
It compiles xinit and passes the native and disposable-container lifecycle tests.
Point `XSH_HOST`, `XSHT`, and `XSH_ROOT` at that snapshot. Set
`XSH_MODULE_PATH` to this checkout. Do not rebuild a moving sibling checkout
while comparing results.

The earlier XSH `7577228454b70be816066fe20d97443dd05dae11` and `f286c59e4`
builds reject this minimized case before any function executes:

```xsh
type ReadyService = module {
  export optional proc ready() [fs, process, env, time, error] -> Result[Bool, Error]
}

proc wait_ready(service_path: Path) -> Result[Bool] {
  let loaded = module.load(service_path)?.require(ReadyService)?
  return true when "ready" not in loaded.keys()
  return true when loaded.ready()
  false
}

print "checked"
```

Their diagnostic is `compact.indexed-build`, with `condition producer has no
checked contract` at `ExprTry`. Both implicit propagation and an explicit `?`
now pass in the supplied repaired build. This was a compiler regression,
not a service-file change.

### Run the independent operational checks

The [closed cohort](DEVELOPMENT.md#closed-cohort-qualification) builds three
actual C, Rust, and XSH packages in two restricted containers. The x86_64 run
passed authority probes and matched all three artifact keys, payload digests,
and archive bytes across different checkout paths and ambient environments.
The native suites do not require Docker.

Follow the [xinit guest instructions](../xinit/tests/README.md) for seeded
scanner actions and the reduced leader-crash replay. These checks use actual
Linux process groups in disposable Docker PID namespaces. The separate PID 1
mode verifies all five signal dispatches and cleanup with zero capabilities.
It expects EPERM from final machine-control syscalls. Controlled startup and
finish-hook interruptions and a bounded failure reducer cover additional
boundaries. Asterinas, aarch64, SIGKILL of the scanner, and disk power loss
remain separate qualification.

The [headless self-hosting proof](SELF-HOSTING.md) builds replacement xsh/xsht
from saved source and crates inside a Linux x86_64 KVM guest. The replacement
rebuilds the closed cohort and composes successor B. Both B and the preserved A
boot with their expected receipts and runner hashes. The same guest qualifies
wall-clock jumps, QMP pause/resume, and the reduced leader-crash counterexample.
This opt-in proof uses declared bootstrap tools and does not qualify a complete
self-hosted package world or production activation.

Run `bash tests/system/network_policy_docker.sh TOOL_SNAPSHOT` to capture a
bounded real virtual-interface observation and reproduce its ownership conflict
offline. This read-only check does not mutate host networking or qualify
reconciliation after partial kernel operations.

The real manual-index check is opt-in:

```bash
(cd packages/mandoc && \
  LAPUTA_MANUAL_INDEX_TOOL_ROOT=/absolute/path/to/mandoc-root \
  "$XSHT" test --jobs 1 tests/manual_index.xsh)
```

Use an absolute `XSHT` path. The package-local configuration discovers this
opt-in test without adding it to the default native suite. Supply a root containing the target's pinned musl mandoc programs and loader.
The check composes two generations, queries original and overlaid manual pages,
compares index bytes, detects alteration or deletion, and preserves the prior
generation when index creation fails. It does not use host `makewhatis`.
