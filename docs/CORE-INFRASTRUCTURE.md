# Core Infrastructure

Laputa is the aarch64-only integration layer for one `qemu-dwl-foot` system.
The sibling `packages` checkout owns recipes, the typed `PackageCatalog`, graph
resolution, and the package-manager CLI. Laputa owns the typed `SystemProfile`,
native `linux/arm64` Docker adapter, image construction, and the QEMU proof.

`pm repo plan` resolves one deterministic `BuildPlan`. Its semantic artifact
keys include the package recipe inputs, `BUILD_EPOCH`, and exact dependency
artifact keys. They deliberately exclude proof scripts, checkout state, runner
fingerprints, remote-index state, and jobs. Bump `BUILD_EPOCH` only when PM/XSH
build semantics can change a payload without recipe-input changes.

The Store is `v2/sha256/<key>/` with only `payload.tar.gz` and `metadata.json`.
Metadata is the package inventory, including file types and Linux modes. A
cached source is revalidated against its declared checksum before use; source
cache location is not artifact identity. Each build and publication invocation
runs the current package proof, including warm and remote-reuse paths. Proof
results are not stored.

`GenerationManifest` selects the runtime-only closure and is written unchanged
to `/var/lib/laputa/generation.json`. The package-tools image is created on
demand from `Dockerfile.package-tools`: pinned aarch64 XSH/core, the explicit
LLVM seed, and the minimal native build/image substrate.

Laputa constructs and verifies the kernel, ext4 root filesystem, and GPT disk
inside Linux, then publishes all of them as one immutable
`builds/<system-key>/` directory. `current` switches atomically to a complete
bundle. `laputa test` and `laputa boot` first ensure that bundle, so QEMU always
uses the kernel and disk from the same current system. The final acceptance
proof boots QEMU with HVF where available, drives the real dwl/foot session
through QMP, and requires the guest success marker plus a screenshot.
