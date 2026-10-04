# Laputa Agent Guide

Laputa is a Linux distribution built and managed in XSH. This monorepo holds
the package manager, the recipes, the system profile CLI, the installer, the
init system, and the package mirror.

Laputa and XSH are co-developed. XSH lives in its own checkout at `../xsh`
(`XSH_ROOT`). Changes to xsh and xsht that make Laputa simpler are welcome;
read `../xsh/AGENTS.md` before editing there or before writing `.xsh` here.

## Layout

| Path | Owns |
|---|---|
| `pm.xsh`, `pm/` | package manager CLI and modules |
| `packages/<name>/` | recipes (`PKGBUILD.xsh`), package proofs, package files |
| `system/`, `laputa.xsh` | typed `qemu-dwl-foot` profile CLI: Docker adapter, image construction, QEMU proof |
| `profiles/`, `guest/`, `boot/` | profile data, guest proof payload, QMP helper |
| `installer/`, `build-installer-*.xsh`, `installer-*.xsh` | aarch64 installer image and its QEMU harness (separate from the profile CLI) |
| `xinit/` | `xinit.xsh`, Laputa's pure-XSH PID 1 and service manager, with tests and docs |
| `mirror/` | Rust package mirror server, a host tool (not a Laputa package) |
| `seed/`, `Dockerfile.package-tools`, `bootstrap-llvm-seed.xsh` | local XSH seed build, the content-keyed host-tools and package-tools images, and the package world on the seed (`seed/world.xsh`) |
| `tests/pm/`, `tests/system/`, `tests/integration/` | native XSH tests; `*/fixtures/` are staged inputs, not tests |
| `docs/` | PM, packaging, development, QEMU, and infrastructure notes |
| `.out/`, `.cache/` | derived state and fetched inputs (gitignored) |

## Commands

The root `Makefile` is the entry point. Host XSH tools default to
`$(XSH_ROOT)/target/release/{xsh,xsht}`; on Linux, when that build is absent,
they are the static binaries `make host-xsh` puts in `.out/host/<arch>/`, so a
Linux host needs only git, make, and Docker (see `README.md`). `ARCH` defaults
to the host architecture. PM tests need `XSH_MODULE_PATH` set to the checkout
root because PM loads recipes and spawns runners at runtime, and the Makefile
sets it.

| Command | Does |
|---|---|
| `make host-xsh` | static musl `xsh`/`xshi`/`xsht` for the host arch in `.out/host/<arch>/`, built in XSH's `xsh-test` image with plain Docker (no host XSH or Rust); shares the seed's cargo target |
| `make check` | `xsht check` over the tree (`xsht-config.ini` owns module path and excludes) |
| `make fetch [ARCH=x86_64]` | the only networked step: pinned upstream sources into `.cache/sources/sha256/` (`pm sources fetch`), XSH's crates, the `xsh-test` image, and the saved host-tools base |
| `make seed [ARCH=…]` | offline: static musl `xsh`/`xshi`/`xsht` and `core.tar.xz` from `XSH_ROOT` into `.out/seed/<arch>/` with a manifest, then the package-tools image |
| `make build [PKGS="a b" \| STOP=pre-cmake]`, `make plan` | PM plan and build in package-tools with `--network none` into `.out/artifacts/<arch>` (the build cache); `STOP=pre-cmake` is `repo plan --all --without cmake --without linux` |
| `make mirror`, `make publish [PKGS=… \| STOP=…]` | the loopback local mirror (foreground; on Linux built by `make host-mirror` in `xsh-test`, elsewhere run through cargo); publish builds the selection, then uploads it from the host |
| `make root PKGS="…"` | import PKGS from the mirror on the host, compose the root offline in a container, check its ELF files load and its xsh runs |
| `make seed-smoke`, `make test-pm-docker` | the seed in package-tools with `--network none`: offline plan plus a PM subset, or the full PM suite |
| `make test` | `test-pm`, `test-system`, `test-xinit` native suites |
| `make mirror-build`, `make mirror-test` | `cargo build`/`cargo test` inside `mirror/` |
| `make profile-{plan,build,test,boot,clean}` | the typed profile CLI in native `linux/arm64` Docker |
| `make installer-image`, `make installer-qemu-test` | aarch64 installer image and QEMU proof |
| `make clean` | remove all derived state (`.out/`, `target/`, mirror frontend outputs, `laputa-*` images); `make distclean` also removes `.cache/` |

Start with the narrowest proof: `xsht check` on changed modules, then their
focused tests (`xsht test tests/pm/pm_plan.xsh`), then the Docker profile
build, and QEMU last. Use `cargo -j 4` and run one test suite at a time.

## Rules

- Do not run formatters or autofixers (`xsht fmt`, `xsht lint --fix`,
  `cargo fmt`, `cargo clippy --fix`). Formatting is the user's job.
- Do not run pre-commit hooks or CI workflows. Never push.
- Keep changes scoped; prefer existing patterns; preserve comments that explain
  why. Add no dependency without a clear need.
- Use typed module imports, structured process argv, explicit effects, and `?`
  at error boundaries. Public exports share a global runtime symbol table, so
  use domain-qualified names where modules could collide.

## PM and recipes

- `pm.xsh` only forwards argv to `pm/cli.xsh`. `pm/recipe.xsh` is the sole
  dynamic recipe boundary. Plans, fingerprints, store, root composition,
  generations, and publication each have one owning module; preserve that
  ownership and avoid abstractions that only rename complexity.
- A package repository root is a directory holding `pm.xsh` and `packages/`;
  in a checkout that is this monorepo. `repository/<path>` recipe sources
  name in-tree inputs (staged through `XSH_PM_REPOSITORY_ROOT` and hashed into
  the recipe fingerprint); `xinit` and `laputa-pm` use them.
- Do not rely on `/bin/sh`, `/usr/bin/sh`, or `SHELL` as a build substrate,
  including indirect paths such as generated Ninja rules. Use XSH `cd` blocks,
  structured `run` argv, direct tool entrypoints, or `#!/bin/xsh` wrappers.
- Sources under a package's `files/generated/` or package-local `files/*.c`
  are package inputs that replace heavyweight generators; keep the generator
  path documented beside them.
- Keep PM tests behavior-oriented; add them when behavior changes or a bug
  needs a regression test, not to raise coverage.

## System profile

- Use the typed CLI, never a handwritten package closure or mutable world root.
- The Docker adapter mounts this checkout read-only at `/src/laputa` (the
  source cache included), the local XSH seed at `/bin/{xsh,xshi,xsht}` and
  `/usr/lib/xsh/core`, and the artifact store `.out/artifacts/<arch>` at
  `/artifacts`, on native `linux/arm64`. No image bakes XSH or PM. Stage
  builds on the container's Linux filesystem and copy only complete, atomic
  final outputs to the host mount.

## xinit

- xinit is PID 1 code: structured argv only, simple shutdown paths, explicit
  process-group ownership, auditable signal handling, no order-dependent
  global state. Test-only switches (`XINIT_TEST_ALLOW_NON_PID1`,
  `XSH_UNIX_DRY_RUN`, `XSH_LINUX_DRY_RUN`) must not change production
  behavior.
- Read `xinit/docs/INIT.md` and `xinit/docs/SUPERVISION.md` before changing
  the inittab engine, the scanner, readiness, or status handling.
- When the service schema changes, update every installed service module in
  the same change (`packages/*/service.xsh` and any generated service text in
  recipes) and check each with `xsh xinit/xinit.xsh -- check PATH`.
