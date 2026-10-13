# Core Infrastructure

Laputa targets `aarch64-linux-musl` and `x86_64-linux-musl`. Each host builds
and proves its own architecture natively: Docker runs on the host's platform,
and QEMU boots the result with hardware acceleration (HVF on Apple Silicon
macOS, KVM on Linux).

## Layout

| Path | Owns |
|---|---|
| `pm.xsh`, `pm/` | package manager CLI and modules |
| `packages/<name>/` | recipes (`PKGBUILD.xsh`), package proofs, package files |
| `system/`, `laputa.xsh` | typed `qemu-dwl-foot` profile CLI: Docker adapter, image construction, QEMU proof |
| `profiles/`, `guest/`, `boot/` | profile data, guest proof payload, QMP helper |
| `infra/asterinas/`, `guest/asterinas/` | pinned Asterinas/Firecracker backend, Laputa guest proof, and serial shell |
| `installer/`, `build-installer-*.xsh`, `installer-*.xsh` | aarch64 and x86_64 installer image and its QEMU harness (separate from the profile CLI) |
| `xinit/` | `xinit.xsh`, Laputa's pure-XSH PID 1 and service manager, with tests and docs |
| `mirror/` | Rust package mirror server, a host tool (not a Laputa package) |
| `seed/`, `Dockerfile.package-tools`, `bootstrap-llvm-seed.xsh` | local XSH seed build, the content-keyed host-tools and package-tools images, and the package world on the seed (`seed/world.xsh`) |
| `tests/pm/`, `tests/system/`, `tests/integration/` | native XSH tests; `*/fixtures/` are staged inputs, not tests |
| `docs/` | development, architecture, PM, VM workflows, testing, and deployment |
| `.out/`, `.cache/` | derived state and fetched inputs (gitignored; `docs/DEVELOPMENT.md` maps them) |

## Ownership

- `pm.xsh`, `pm/`, and `packages/` own recipes, the typed `PackageCatalog`,
  graph resolution, the `BuildPlan`, artifact storage, root composition, and
  publication.
- `seed/` owns the local XSH seed, the two Docker images, and the package world
  behind `make plan/build/publish/root`.
- `system/` and `laputa.xsh` own the typed `SystemProfile` for
  `qemu-dwl-foot`: the native Docker adapter, image construction, and the QEMU
  proof. `system/qemu.xsh` picks the QEMU target for the host.
- The installer (`installer/`, `build-installer-*.xsh`, `installer-*.xsh`)
  composes its roots from the local mirror; see [installer](INSTALLER.md).

The boundary between PM and its consumers is narrow:

- recipes declare a typed package kind, files, sources, dependencies, and a
  payload build and proof contract;
- `pm repo plan` produces the only package-resolution result;
- `pm repo build` creates or verifies immutable artifacts;
- `pm root compose` creates a verified runtime-only generation;
- the profile and the installer pass package roots and output locations into
  that contract and use the resulting generation, kernel, and image files.
  They never resolve a package closure themselves or install into a mutable
  package world.

A build may use declared host or target build dependencies, but those tools
never become runtime content without an explicit runtime edge.

## Identity and the store

`pm repo plan` resolves one deterministic `BuildPlan`. Its artifact keys
cover the target, the recipe inputs, `BUILD_EPOCH`, and the exact keys of the
build dependencies. They deliberately exclude proof scripts, checkout state
(paths, mtimes, `.git`, and file modes beyond git's 0755/0644 model), the XSH
runners, the PM tree and core applets, remote-index state, and job counts.
Bump `BUILD_EPOCH` only when a PM or XSH change can alter a payload without
any recipe change.

The store is `v2/sha256/<key>/` with `artifact.json`, `payload.tar.gz`,
`metadata.json`, and `proof.json`. Metadata is the package inventory,
including file types and Linux modes, plus the executor provenance. A cached
source is revalidated against its declared checksum before use; where it came
from is not artifact identity. A changed proof re-proves an unchanged artifact
and stores the result under `v2/proofs/<key>/`. [PM](PM.md) has the full
contract.

## Images and the seed

The package-tools image is built on demand from `Dockerfile.package-tools`
without network: the saved `laputa-host-tools` base (pinned Alpine and its
native build and image tools) plus the explicit LLVM seed. It holds no XSH;
containers mount the local seed from `.out/seed/<arch>/`, binaries and core
together.

## System images

`GenerationManifest` selects the runtime-only closure and is written unchanged
to `/var/lib/laputa/generation.json`. The profile build constructs and
verifies the kernel, ext4 root filesystem, and GPT disk inside Linux, then
publishes all of them as one immutable `builds/<system-key>/` directory.
`current` switches atomically to a complete bundle. `laputa test` and
`laputa boot` first ensure that bundle, so QEMU always uses the kernel and
disk from the same current system. The acceptance proof boots QEMU with
hardware acceleration, drives the real dwl and foot session through QMP, and
requires the guest success marker plus a screenshot; see [QEMU proof](QEMU.md).

## Implementation constraints

Use typed module imports, structured process argv, explicit effects, and `?`
at error boundaries. Public exports share a global runtime symbol table; use
domain-qualified names where modules could collide.

`pm.xsh` forwards argv to `pm/cli.xsh`; `pm/recipe.xsh` is the sole dynamic
recipe boundary. Plans, fingerprints, store, root composition, generations, and
publication each retain one owning module.

Use the typed system CLI rather than handwritten closures or mutable world
roots. The Docker adapter mounts the checkout read-only at `/src/laputa`, the
seed at `/bin/{xsh,xshi,xsht}` and `/usr/lib/xsh/core`, the artifact store at
`/artifacts`, and the Kbuild cache from `.out/cache/linux-kbuild`. Stage builds
on the container filesystem and copy only complete, atomic outputs to host
mounts. `system/qemu.xsh` owns machine, accelerator, console, block transport,
and display; profiles hold system intent.
