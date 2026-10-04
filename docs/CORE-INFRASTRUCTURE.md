# Core Infrastructure

Laputa targets `aarch64-linux-musl` and `x86_64-linux-musl`. Each host builds
and proves its own architecture natively: Docker runs on the host's platform,
and QEMU boots the result with hardware acceleration (HVF on Apple Silicon
macOS, KVM on Linux).

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
  composes its roots from the local mirror; see `INSTALLER.md`.

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
