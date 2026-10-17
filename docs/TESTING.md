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
```

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

Use `cargo -j 4` for Rust checks. `make mirror-test` checks the mirror and its
POSIX deployment scripts; on Linux it runs Cargo offline in `xsh-test`.
`make verify` is the full host proof from a clean build, with logs and a timing
table under `.out/verify/`; reserve it for an explicit full verification run.

The bootstrap campaign completed a clean x86_64 world build and both QEMU
proofs. Its later shared-path changes did not receive a full aarch64 rebuild
or boot proof. Track that verification gap in [TODO](../TODO.md).
