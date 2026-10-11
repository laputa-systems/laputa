# Implement Native Asterinas + Laputa on Firecracker

## Mission

Implement a complete, fully unattended development and testing environment that boots **the native Asterinas kernel inside a Firecracker microVM, running the actual Laputa distribution as its userspace**, with XSH as the principal shell, system tooling, and init implementation.

This is an implementation task, not a research or design-document task.

**Do not stop at a prototype, successful compilation, or partial boot. Continue implementing, debugging, and testing until the acceptance criteria below are satisfied.**

Work autonomously. Make technical decisions yourself using existing repository conventions. Do not request confirmation, present implementation options for approval, or stop after generating a plan.

The intended final outcome is that a developer on an x86-64 Linux machine with KVM can execute:

```sh
make asterinas-build
make asterinas-test
make asterinas-boot
```

And obtain:

1. A reproducibly built Asterinas kernel.
2. An authentic Laputa userspace derived from its existing package manager.
3. A Firecracker-compatible bootable system.
4. An automated guest test that actually executes XSH under Asterinas.
5. An interactive development VM running Laputa.
6. Persistent, inspectable logs and build artifacts.
7. Correct incremental rebuilding when XSH or relevant inputs change.

**The system running inside Firecracker must be Asterinas + Laputa, not Linux + Laputa, NixOS, or an upstream BusyBox demonstration.**

## Repositories

Primary repository:

https://github.com/laputa-systems/laputa

Companion XSH repository:

https://github.com/laputa-systems/xsh

Asterinas upstream:

https://github.com/asterinas/asterinas

Expected checkout layout:

```text
workspace/
├── laputa/
└── xsh/
```

Laputa uses `../xsh` by default through `XSH_ROOT`.

If either checkout is missing, locate or clone it as appropriate. Preserve preexisting local changes. Never discard unrelated user modifications.

Treat Laputa as the primary implementation repository. Modify XSH only when genuine runtime, kernel-compatibility, or testing changes are necessary.

Read these before editing:

Laputa:
- `AGENTS.md`
- `README.md`
- `Makefile`
- `docs/DEVELOPMENT.md`
- `docs/CORE-INFRASTRUCTURE.md`
- `docs/QEMU.md`
- `docs/PM.md`
- `system/`
- `seed/`
- `pm/`
- `xinit/docs/INIT.md`
- `xinit/docs/SUPERVISION.md`

XSH:
- `AGENTS.md`
- `docs/user-tour.md`
- `docs/ARCHITECTURE.md`
- `docs/TESTING.md`
- `core/SYSTEM-REPORT.md`

Also examine existing package recipes, test infrastructure, and the source of the current boot hooks.

Respect repository rules, particularly:

- No formatters or automatic fixers.
- No unnecessary dependencies.
- No pre-commit hooks or CI workflow invocations.
- Never push.
- Use XSH idioms and structured process arguments.
- Follow existing error-handling and test conventions.
- Avoid duplicating logic already owned by another module.

## Architectural intent

Laputa already possesses significant infrastructure:

- A package manager implemented in XSH.
- Content-addressed package artifacts.
- Deterministic package planning.
- Immutable runtime generations.
- Atomic publication of system bundles.
- Static musl builds of `xsh`, `xshi`, and `xsht`.
- A pure-XSH PID 1 implementation (`xinit`).
- Native filesystem, process, networking, and system-management tools.
- Existing QEMU proofs and host-side supervision.

**Reuse these components. Do not build a separate minimalist distribution alongside Laputa.**

Asterinas should be another kernel capable of running Laputa, not the reason to introduce a second distribution architecture.

The desired system is:

```text
Linux x86-64 host
    |
    +-- Docker (build-time only)
    |
    +-- Firecracker / KVM
            |
            +-- Asterinas kernel
                    |
                    +-- Laputa initramfs
                            |
                            +-- ext2 root filesystem
                                    |
                                    +-- musl
                                    +-- xsh / xshi / xsht
                                    +-- XSH core commands
                                    +-- xinit (PID 1)
                                    +-- Laputa system configuration
                                    +-- development tests
```

## Preliminary host and kernel setup

The implementation pins Asterinas, its development image, Firecracker, and XSH
in `infra/asterinas/inputs.lock`. `make asterinas-setup` builds that kernel
with the pinned development image and boots a small smoke initramfs on host KVM
until the guest prints a serial marker. This only checks the kernel and VMM
path; `make asterinas-test` verifies the Laputa userspace. Repeated builds reuse
the kernel when its source, toolchain image, build flags, and initramfs inputs
match.

Docker is acceptable as a **host-side build tool**, as it already is throughout Laputa.

There must be no Docker dependency inside the guest.

## Explicit exclusions

Do not introduce:

- Nix or NixOS as a build requirement, package manager, runtime, or guest component.
- systemd.
- D-Bus.
- A second package manager.
- A second, independent root filesystem composer.
- Buildroot, Yocto, or an Alpine installation transplanted into the guest.
- A Linux kernel inside the guest.
- A mandatory BusyBox userspace.
- Kubernetes, Docker Engine, Podman, or container orchestration inside the guest.
- A daemon or persistent broker to manage VM sessions.
- A bespoke replacement for Firecracker.
- A heavyweight generalized hypervisor abstraction.
- An unnecessary Rust service or orchestration binary.
- A Wayland desktop or graphics stack in the initial Firecracker target.

This environment is intentionally **headless, serial-console-oriented, and optimized for rapid XSH development and kernel ABI validation**.

Retain the existing graphical `qemu-dwl-foot` profile without modification to its intended behavior.

## Phase 1 — Investigate existing infrastructure

Inspect Laputa's current implementation carefully.

Particularly relevant files include:

- `system/build.xsh`
- `system/container_build.xsh`
- `system/container_output.xsh`
- `system/docker.xsh`
- `system/image.xsh`
- `system/profile.xsh`
- `system/types.xsh`
- `system/qemu.xsh`
- `profiles/qemu-dwl-foot.xsh`
- `packages/xsh/PKGBUILD.xsh`
- `packages/xinit/PKGBUILD.xsh`
- `packages/baselayout/PKGBUILD.xsh`
- `packages/baselayout/files/rootfs/etc/inittab`
- `packages/baselayout/files/rootfs/usr/lib/init/rc.boot`
- `packages/laputa-fs/`
- `guest/`
- `tests/system/`

Understand the precise relationship between BuildPlan, GenerationPlan, immutable package artifacts, profile overlays, runtime closure, root image construction, and atomic publication.

An important existing limitation is that `SystemProfile` assumes a kernel package in the PM plan and that `system/image.xsh` constructs ext4 root filesystems and GPT disk images.

Asterinas should not inherit those assumptions unnecessarily.

Determine the smallest architectural extension that permits a kernel built outside the Laputa package closure while continuing to reuse its immutable-generation machinery.

Prefer a dedicated Firecracker/Asterinas backend over introducing extensive branching into the working Linux/QEMU path.

Preserve ownership boundaries. Refactor shared generation logic if justified, but do not fork or copy its implementation.

## Phase 2 — Establish a pinned, reproducible Asterinas kernel build

Study the current Asterinas source and documentation.

Relevant upstream references:

- https://github.com/asterinas/asterinas/blob/main/book/src/kernel/firecracker.md
- https://github.com/asterinas/asterinas/blob/main/tools/firecracker_args.sh
- https://github.com/asterinas/asterinas/blob/main/OSDK.toml
- https://github.com/asterinas/asterinas/blob/main/Makefile
- https://github.com/asterinas/asterinas/blob/main/test/initramfs/src/init
- https://github.com/asterinas/asterinas/blob/main/distro/etc_nixos/modules/core.nix

Asterinas has native Firecracker support through its x86-64 PVH boot protocol.

`infra/asterinas/setup.sh` invokes `cargo osdk build` in the selected official
development container with the externally generated smoke initramfs, direct
VMM boot, x86-64 target, and `pvh_boot` feature. It checks the resulting PVH
ELF and records its SHA-256. The Laputa target builds its own separate
initramfs; neither path invokes Nix or consumes a Nix-produced filesystem.

The lock currently selects Asterinas commit
`81b2faa0883cc05e7b8a93dd053aa00a1f6eddea`, dev image
`0.18.1-20260926` at digest
`sha256:e4a5a5742247a287af70d1d5b59f5fa93fe8ab46dcc9081a5e3d0a8066faab56`,
Firecracker `v1.17.0`, and XSH commit
`76bc2de87d96040244248f3ca0ba478801ec4969`. Update these pins deliberately.

The build uses the Asterinas source and XSH source archives in managed caches,
so it does not move or edit the developer's XSH branch. The runtime root is
composed by PM from `baselayout`, `xsh`, `laputa-pm`, and `xinit`; the root
image is a raw ext2 filesystem. The guest initramfs uses a small freestanding
static syscall bootstrap because the XSH process runtime starts a preparation
thread and Asterinas waits for sibling threads during `execve`; ordinary init
policy stays in the packaged XSH `xinit` and boot hooks.

The setup validates source/toolchain compatibility, builds into managed output,
records the source, image, build configuration, and kernel hash, and reuses the
kernel when its inputs are unchanged. Update the pins in the lock deliberately.

Use Laputa's existing cache conventions where applicable.

Do not vendor the entire Asterinas repository into Git. Keep downloaded source and compilation artifacts in explicitly managed, gitignored cache/output directories.

A developer should not need to manually build Asterinas before invoking the new Laputa targets.

## Phase 3 — Build an authentic minimal Laputa userspace

Create a new minimal Laputa runtime profile or equivalent typed system definition for Asterinas.

Its initial direct package intent should be approximately:

```text
baselayout
musl
xsh
xinit
```

Include `laputa-pm` or additional small packages only when their functionality is genuinely useful for the developer environment.

Resolve the actual closure through Laputa's package manager.

Never hardcode a package dependency closure.

Crucially:

- Do not pull in the `linux` kernel package.
- Do not use `linux` package artifacts as the guest kernel.
- Do not include the full graphical profile.
- Do not include the compiler or LLVM toolchain in the runtime unless specifically required.
- Retain XSH's normal installed core command scripts.
- Retain Laputa's ordinary configuration files and directory layout.

The XSH package already installs static `xsh`, `xshi`, and `xsht` binaries plus `/usr/lib/xsh/core`.

Use the existing seed-building infrastructure to obtain them.

Ensure x86-64 musl binaries are produced and verify their ELF properties. Static bootstrap executables must have no unresolved dynamic interpreter requirements.

The resulting guest must be recognizably Laputa.

Preserve `/etc/os-release`, standard filesystem layout, and ordinary XSH command behavior.

## Phase 4 — Implement a genuine ext2 root filesystem

Asterinas supports ext2, whereas full ext4 compatibility remains incomplete.

Laputa currently creates an ext4 root image.

**Do not attempt to mount Laputa's existing ext4 image as ext2 and assume it is compatible.**

Introduce an explicit ext2 output for the Asterinas backend.

The preferred implementation is a raw ext2 filesystem image populated from Laputa's existing immutable runtime generation.

Avoid GPT and partitioning initially. Firecracker can attach the raw ext2 filesystem as a virtio block drive, and the guest can mount `/dev/vda`.

Investigate reuse of the existing XSH filesystem formatting code. If it cannot produce a genuinely valid ext2 image cleanly, use the smallest reliable host-side ext2 formatting utility, such as `mke2fs -t ext2 -d`, within the pinned build environment.

Do not undertake a wholesale filesystem formatter rewrite merely to eliminate a build-time tool.

Requirements:

- Preserve files, modes, symlinks, ownership, and required directories.
- Ensure installed XSH scripts and executable links remain correct.
- Provide enough writable filesystem space for normal runtime behavior and tests.
- Do not rely on root privileges to mount a loopback image on the host.
- Verify the filesystem type and critical ext2 feature flags.
- Run host-side filesystem consistency checks.
- Fail on unsupported ext4-only features.
- Preserve generation provenance.
- Publish the image atomically.
- Never select a partially constructed image as current.

Make warm builds reuse completed valid artifacts.

The filesystem should contain the same verified Laputa generation that the build plan selected.

For future compatibility, keep the filesystem format explicit rather than making it an implicit property of the kernel name.

## Phase 5 — Implement the Laputa initramfs and boot transition

Create a very small, explicit initramfs for the Asterinas target.

It should be generated deterministically as a `newc` CPIO archive, optionally gzip-compressed.

The initramfs should contain only the minimum necessary to boot into the real Laputa root:

- An executable `/init`.
- A static XSH runtime and any necessary XSH core support.
- Required filesystem mountpoints.
- Minimal boot configuration.

Use XSH for the early boot script when supported.

The expected lifecycle is:

1. Firecracker loads Asterinas and the Laputa initramfs.
2. Asterinas starts `/init` as PID 1.
3. Early init establishes the required pseudo-filesystems and device access.
4. The virtio block device becomes accessible.
5. The ext2 root at `/dev/vda` is mounted.
6. Basic rootfs integrity and required executables are checked.
7. Control is transferred to the real Laputa root using correct `switch_root` semantics.
8. Laputa's existing `xinit` takes over as PID 1.
9. Laputa's normal boot hooks initialize the userspace.
10. The developer shell or guest test begins.

Read Asterinas's existing `stage-1-init` implementation for its expected mount behavior, but do not copy its NixOS paths.

Be particularly careful about:

- `/dev` and devtmpfs availability.
- `/proc` and `/sys`.
- `/dev/pts` and `/dev/ptmx`.
- Executable shebang behavior.
- Mount ordering.
- Root filesystem device discovery.
- PID 1 preservation.
- Correct `switch_root` behavior.
- File descriptor and controlling-terminal handling.
- Serial console visibility.
- Clean shutdown.

The existing Laputa boot hooks may contain Linux-specific assumptions. Identify and correct only those that affect real Asterinas compatibility.

Do not introduce a blanket `ASTERINAS=1` mode that suppresses failing operations.

Where kernel-specific behavior is necessary, encode a narrow, documented compatibility decision.

If an XSH-based initramfs bootstrap proves impossible because of a genuine early-boot capability gap, a very small static bootstrap executable is permissible as a last resort. Document why it is needed and keep all ordinary init policy in XSH.

Do not silently replace `xinit` with BusyBox init.

## Phase 6 — Implement the Firecracker host backend

Add a dedicated backend, preferably following the style of the existing typed `system/` modules.

It must manage:

- Exact kernel selection.
- Initramfs selection.
- Root filesystem selection.
- Firecracker configuration generation.
- Host preflight validation.
- VM startup and process supervision.
- Interactive serial access.
- Console and stderr logs.
- Test deadlines.
- Panic and error detection.
- Guest shutdown.
- Cleanup after failure.
- Result reporting.

Use structured process arguments, not string-built shell commands.

A minimal Firecracker configuration resembles:

```json
{
  "boot-source": {
    "kernel_image_path": "/absolute/path/asterinas.elf",
    "initrd_path": "/absolute/path/laputa.cpio.gz",
    "boot_args": "console=ttyS0 rdinit=/init"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "/absolute/path/laputa.ext2",
      "is_root_device": false,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 1024
  }
}
```

This is an illustrative configuration, not a substitute for validating current Firecracker and Asterinas behavior.

Generate correct absolute paths and properly escaped JSON through the available structured JSON facilities.

Use an appropriate kernel command line, including necessary console and logging parameters.

Do not rely on a bootloader, EFI firmware, or Linux `bzImage` conversion when the documented direct PVH ELF path works.

Initially target:

```text
Host OS: Linux
Host architecture: x86_64
Virtualization: KVM
Guest architecture: x86_64
Console: ttyS0
Kernel: native Asterinas
Rootfs: ext2
```

Preflight should verify:

- Host architecture and operating system.
- KVM availability and access.
- Firecracker availability and compatible version.
- Docker access for required builds.
- Required source checkouts.
- Pinned build inputs.
- Required image-generation tools.
- Correct kernel, initramfs, and rootfs artifacts before VM startup.

Handle unsupported hosts explicitly.

macOS cannot run Firecracker directly using its native Hypervisor.framework backend. Do not silently substitute QEMU or claim Firecracker verification on macOS.

A Linux x86-64 host with usable KVM is the required end-to-end execution environment.

Avoid broad host-side privileges. Do not require privileged Docker for running Firecracker if a narrower configuration works.

Do not leave behind running Firecracker processes, temporary sockets, TAP devices, or other VM state.

Use bounded shutdown escalation and ensure child processes are reaped.

## Phase 7 — Expose a clean Make interface

Implement these targets:

```sh
make asterinas-setup
make asterinas-preflight
make asterinas-fetch
make asterinas-build
make asterinas-test
make asterinas-boot
make asterinas-clean
```

Intended behavior:

**`asterinas-preflight`**

Perform host and toolchain checks, print concise actionable failures, and perform no destructive changes.

**`asterinas-fetch`**

Fetch pinned Asterinas source and required build inputs. Verify their identities. Keep network access confined to explicit fetch operations whenever practical.

**`asterinas-build`**

Build or reuse the XSH seed, selected Laputa packages, runtime generation, Asterinas kernel, initramfs, and ext2 rootfs.

Produce one verified, immutable system bundle.

**`asterinas-test`**

Build or refresh the system, launch Firecracker, execute the guest proof, verify its result, terminate the VM, and return a truthful shell exit status.

No interactive input required.

**`asterinas-boot`**

Build or refresh the system, then launch Firecracker with an interactive serial-console Laputa environment suitable for development.

**`asterinas-clean`**

Remove only this backend's derived state and transient runtime resources.

Do not remove the shared package artifact store or unrelated Linux/QEMU generations.

Match existing Makefile conventions for variables, diagnostics, and cleanup.

The Asterinas backend pins XSH independently of the developer's `XSH_ROOT`
working tree. Existing non-Asterinas Make targets continue to use `XSH_ROOT`.

Do not add an unnecessarily broad new set of configuration options.

## Phase 8 — Build a strong in-guest XSH proof

Create a dedicated, real guest test program under the appropriate Laputa `guest/` location.

The test must execute inside Firecracker under Asterinas, not on the host.

It must prove the actual Laputa/XSH environment is functional.

At minimum validate:

### Identity and boot

- Kernel booted to userspace.
- Real Laputa root filesystem is mounted.
- `/etc/os-release` identifies Laputa.
- XSH executes successfully.
- `xinit` starts as PID 1.
- `/proc`, `/sys`, and `/dev` are available as required.
- Kernel and boot artifacts correspond to the selected build manifest.

Do not rely solely on `uname` to establish kernel identity; Asterinas may emulate Linux identity for ABI compatibility.

Validate the host-selected Asterinas ELF through hashes and boot provenance, complemented by actual kernel boot evidence.

### XSH execution

- Execute a simple XSH program.
- Exercise typed values and evaluation.
- Import a core module.
- Execute a subprocess.
- Verify exit status propagation.
- Verify stdout and stderr handling.
- Verify filesystem operations.
- Verify path and symlink behavior.
- Verify process spawning and waiting.
- Verify environment variables.
- Verify basic signals.
- Verify a pipeline or stream.
- Exercise several installed XSH core commands.

Where suitable, use existing native XSH tests rather than duplicating their assertions.

### Filesystem

- Create a regular file.
- Read it.
- Modify it.
- Rename it.
- Verify its contents.
- Remove it.
- Exercise directory traversal.
- Verify permissions and metadata.
- Demonstrate that writes affect the ext2 root filesystem.

### Process and system interfaces

Exercise a representative set of XSH's Linux-backed APIs relevant to Laputa, including basic process, filesystem, and system-report functionality.

Look for actual ABI incompatibilities.

Do not paper over failures by silently dropping tests.

### Terminal

Test available PTY and terminal functionality required for an interactive shell.

An interactive `asterinas-boot` must provide a usable serial-console shell and not merely boot into a noninteractive service process.

### Networking

Basic loopback socket behavior should be tested when supported.

Full host/guest networking may require TAP configuration. Avoid making privileged host networking a prerequisite for the initial core proof.

If practical, expose an additional targeted networking proof without introducing permanent host networking changes.

## Phase 9 — Machine-verifiable acceptance protocol

Create a clean, auditable guest-to-host success protocol.

For example, emit the following over the guest serial console:

```text
LAPUTA_ASTERINAS_BOOT_OK
LAPUTA_ASTERINAS_XSH_OK
LAPUTA_ASTERINAS_TEST_OK
```

Use an explicit failure marker such as:

```text
LAPUTA_ASTERINAS_TEST_FAILED <phase>: <reason>
```

Markers must only be emitted after the corresponding in-guest assertions have genuinely passed.

The host runner must:

1. Launch the VM.
2. Capture serial output and Firecracker diagnostics.
3. Detect boot panics and fatal failures.
4. Require the expected guest success markers.
5. Require the guest test to finish successfully.
6. Require clean shutdown or an explicitly documented supported completion protocol.
7. Fail if the VM exits early without a complete proof.
8. Fail on timeout.
9. Fail on guest test errors.
10. Clean up every process and temporary resource.

Never interpret mere VM startup, a Firecracker process exit of zero, or a logged string that the host itself supplied as successful execution of XSH.

The test runner must return a nonzero exit code on failure.

Preserve diagnostics even when tests fail.

## Phase 10 — Establish a useful XSH development workflow

The primary purpose of this environment is ongoing XSH development. The
Asterinas workflow uses the XSH commit in `infra/asterinas/inputs.lock`; a
different XSH revision must be committed and selected there before its seed or
runtime package is rebuilt. Laputa also pins its Asterinas compatibility fork
as the `asterinas/` submodule. Developers can edit that checkout and run the
local integration proof with `ASTERINAS_LOCAL=1`; the source snapshot is
fingerprinted into the kernel build key.

Design the incremental build dependencies so that:

- Modifying XSH invalidates the relevant XSH seed and runtime package artifacts.
- Modifying a guest test invalidates the relevant test payload.
- Modifying an initramfs script invalidates the initramfs.
- Modifying Asterinas or its kernel configuration invalidates the kernel.
- Unchanged Asterinas inputs reuse the existing kernel.
- Unchanged packages reuse Laputa's content-addressed artifacts.
- Unchanged generations reuse valid images.
- Test logs are never mistaken for reusable build artifacts.

Expose a narrow way to run one existing XSH test module from the locked source
snapshot inside the Asterinas guest:

```sh
make asterinas-test XSH_TEST=tests/xsh/stdlib/fs.xsh
```

Use the packaged `xsht` native test runner and stage the test tree through a
PM generation overlay whose digest participates in the system key. The
`fs.xsh` suite exercises kernel-enforced rooted filesystem operations and
should run against Laputa's Asterinas fork.

Do not require the developer to manually copy files into a mounted disk image.

Prefer reproducible, boot-time test execution over complicated long-lived RPC machinery.

Keep the base system reusable across different test selections when technically appropriate.

## Phase 11 — Failure investigation and compatibility fixes

Expect real compatibility gaps.

Asterinas is a developing Linux-compatible kernel, not a perfectly interchangeable Linux implementation.

Investigate failures at the correct layer.

Possible categories include:

- Missing or partially implemented syscalls.
- Incorrect syscall errno behavior.
- Differences in procfs or sysfs.
- Device discovery or devtmpfs behavior.
- Filesystem feature compatibility.
- Mount propagation and root transitions.
- Signal delivery.
- Process-group and session management.
- Controlling terminals and PTYs.
- `clone`, `fork`, `execve`, and `wait` semantics.
- Time and clock interfaces.
- Socket or network behavior.
- Resource limits.
- Kernel crashes.

Use serial logs, kernel diagnostics, available syscall tracing, and small standalone reproducers.

Prefer minimal, isolated tests that establish the exact failing behavior.

Distinguish:

1. A bug in Laputa.
2. A bug in XSH.
3. An invalid assumption in the integration.
4. An actual Asterinas Linux-ABI compatibility gap.

Fix Laputa defects in Laputa and XSH defects in XSH. When a syscall required by
Laputa, XSH, or a selected guest test is missing or incomplete in Asterinas,
implement its Linux ABI behavior in the pinned `asterinas/` fork and add
kernel-side regression coverage. Keep the fork focused on compatibility needed
by Laputa, and include the source revision and tests in the normal local build
and guest verification workflow.

The rooted filesystem APIs in XSH require `openat2(2)`. The pinned fork now
implements syscall 437 for x86-64 and the generic syscall table, validates the
`open_how` ABI, and enforces the supported `RESOLVE_*` constraints during path
lookup. Its regression source is under
`asterinas/test/initramfs/src/regression/fs/openat2/`; the Laputa guest proof
also runs `tests/xsh/stdlib/fs_root_children.xsh` against the built kernel.

The pinned VFS now carries raw pathname bytes through path resolution, dentry
cache keys, ext2 and ramfs directory operations, symlink targets, metadata
syscalls, `getdents64`, and inotify event names. The ext2 openat2 regression
creates, reads, enumerates, and unlinks a filename containing `0xff`. The
complete `tests/xsh/stdlib/fs.xsh` module passes in the Laputa guest; its two
permission tests skip because the guest runs as root, which the tests report
explicitly.

Filesystems that use the default `Inode` byte-name adapters accept UTF-8 names
and return `EILSEQ` for invalid bytes; ext2 and ramfs implement byte names
directly. The `mount(2)` source field remains a UTF-8 string and returns
`EILSEQ` for an invalid source because filesystem creation and mount metadata
currently represent it as `str`.

Do not replace missing kernel behavior with a userspace emulation, weaken a
security guarantee, or skip the test that exposed the gap. Optional interfaces
outside Laputa's runtime and selected tests may remain unsupported when their
scope and observed errno are documented precisely.

The final boot and basic XSH proof must pass without such waivers.

## Phase 12 — Tests for the host implementation

Add native tests for the new host orchestration, preferably under `tests/system/` or another existing appropriate test location.

Cover at least:

- Host architecture rejection.
- Missing KVM access.
- Missing Firecracker executable.
- Missing or corrupt kernel.
- Missing or corrupt initramfs.
- Missing or corrupt ext2 image.
- Incorrect filesystem type.
- Wrong artifact architecture.
- Invalid configuration.
- Deterministic configuration generation.
- Correct build dependency invalidation.
- Warm build reuse.
- Interrupted build publication.
- Failed or incomplete guest proof.
- Early VM exit.
- Guest kernel panic.
- Guest test timeout.
- VM cleanup after errors.
- Preservation of unrelated build outputs.

Where possible, test process-management behavior with fake executables, following existing repository techniques.

Do not require every unit test to launch a real VM.

Reserve real KVM execution for the integration proof.

A failing kernel test must not publish a successful test result.

## Phase 13 — Immutable outputs and provenance

Follow Laputa's existing output conventions.

Use a directory such as:

```text
target/laputa/asterinas-firecracker/
├── builds/
│   └── <system-key>/
│       ├── build-plan.json
│       ├── generation.json
│       ├── kernel.elf
│       ├── initramfs.cpio.gz
│       ├── rootfs.ext2
│       ├── firecracker.json
│       └── manifest.json
├── current -> builds/<system-key>
├── test-console.log
├── test-firecracker.log
├── boot-console.log
├── boot-firecracker.log
└── viability-result.txt
```

Adjust names to fit existing conventions, but preserve the principles.

The system key must reflect the relevant immutable build inputs.

The manifest should identify:

- Laputa generation digest.
- XSH seed/build identity.
- Asterinas commit.
- Asterinas build configuration.
- Toolchain identity.
- Kernel image SHA-256.
- Initramfs SHA-256.
- Rootfs SHA-256.
- Guest test payload identity where applicable.

The manifest records the selected test module path and source hash, the
profile proof source hash, the Asterinas kernel build configuration, and the
toolchain image identity and compiler versions.

Rebuilds should not reuse artifacts when their semantic inputs changed.

Publish only fully verified bundles.

Follow `system/container_output.xsh` rather than inventing another publication framework.

Use atomic filesystem operations, correct cleanup, and hash validation.

## Phase 14 — Documentation

Update the root `README.md`, `AGENTS.md`, Makefile command descriptions, and the nearest relevant development documentation.

Add a focused guide, such as:

```text
docs/ASTERINAS.md
```

Include:

- Purpose and scope.
- Supported host platform.
- Required tools.
- Architecture diagram.
- Kernel source and build pinning.
- Exact Make targets.
- Boot sequence.
- Image layout.
- Filesystem choice and ext4 limitation.
- Interactive shell usage.
- XSH test selection.
- Where artifacts and logs live.
- Kernel compatibility limitations.
- How to update Asterinas deliberately.
- Troubleshooting boot failures.
- How to clear rebuildable checkout state for a cold campaign rebuild.

Keep documentation factual and tied to verified implementation.

Do not describe untested features as supported.

## Phase 15 — Verification gates

Work through these gates in order, but do not stop after any intermediate success.

### Gate A: Static correctness

- New source passes XSH checking.
- Host orchestration tests pass.
- Generated configuration is valid.
- Source and toolchain pins are valid.
- Build outputs have correct types.
- Filesystem image passes offline verification.
- No prohibited runtime components appear in the guest closure.

### Gate B: Kernel verification

- Pinned Asterinas kernel builds.
- ELF architecture and PVH support are correct.
- Firecracker accepts the kernel.
- Asterinas reaches the initramfs.
- Logs conclusively show a genuine kernel boot.

An upstream BusyBox or trivial-initramfs boot may be used temporarily as a diagnostic, but does not satisfy the final acceptance criteria.

### Gate C: Real Laputa boot

- Laputa initramfs starts.
- Root filesystem mounts.
- `switch_root` succeeds.
- `xinit` becomes PID 1.
- Laputa startup completes.
- A real XSH process executes.
- The console is usable.

### Gate D: Guest test

- Every required guest smoke test passes.
- The success protocol is complete.
- Firecracker shuts down correctly.
- The host exits successfully.
- Diagnostic logs and result metadata are preserved.

### Gate E: Reproducibility and incremental builds

- Run the build twice with unchanged inputs.
- Confirm the second build reuses the correct artifacts.
- Confirm stable content hashes wherever deterministic construction is promised.
- Modify a test input and verify correct invalidation.
- Modify an XSH input and verify correct invalidation.
- Confirm the Asterinas kernel is not unnecessarily rebuilt for XSH-only changes.
- Confirm an interrupted build cannot corrupt the published system.

### Gate F: Regression

Run relevant existing Laputa verification, including:

```sh
make check
make test-system
make test-xinit
```

Run the existing Linux/QEMU profile tests if shared system-generation or image code was changed.

If XSH itself was modified, run its corresponding native and Linux verification gates from `docs/TESTING.md`, using its required build environment.

Do not regress the existing Linux distribution, package manager, installer, or graphical QEMU profile.

### Gate G: Repeated cold boot

Run the completed Firecracker guest proof multiple times from a stopped state.

Verify consistent successful boot, execution, and shutdown.

Check for orphaned processes and leaked runtime artifacts after every iteration.

The final integration result must be based on the actual Firecracker/Asterinas/Laputa stack.

## Phase 16 — Autonomous execution protocol

Operate as an autonomous implementation agent.

Follow this loop:

1. Inspect the relevant code and documentation.
2. Implement the smallest coherent next change.
3. Run the narrowest useful test.
4. Diagnose any failure.
5. Correct its actual cause.
6. Run the test again.
7. Run the next broader verification gate.
8. Continue until the acceptance criteria pass.

Do not ask me what to do next.

Do not stop merely because:

- The initial build failed.
- An upstream command changed.
- A compiler error occurred.
- A syscall behaved unexpectedly.
- Firecracker initially failed to boot.
- The root filesystem failed to mount.
- The init script failed.
- The guest console was unavailable.
- An assertion failed.
- An integration test timed out.
- A generated image was malformed.
- A dependency needs an adjustment.
- A test revealed a genuine implementation bug.

Diagnose, fix, and rerun.

Do not accept a mock test as a replacement for actual VM verification.

Do not mark tasks complete merely because their source files exist.

Do not weaken required tests to obtain success.

Keep the work incremental, with bounded individual command timeouts and inspectable logs. Prevent infinite retries of an identical failing command without changing the diagnosis or environment.

If the execution environment genuinely lacks access to KVM, first determine whether a configured, authorized x86-64 Linux execution host is available. Complete every possible build and static gate, but do not falsely claim the Firecracker acceptance test passed.

Do not use a Linux/QEMU fallback and label it Asterinas verification.

Never make destructive host-level changes, disable security controls, or assume permission to install privileged system components simply to make a test pass.

A genuine externally imposed hardware or permission blocker must be reported precisely; it is not permission to fabricate success.

## Phase 17 — Final deliverable

Before finishing, ensure the working tree contains a complete, coherent implementation rather than abandoned experiments.

Remove temporary debug hacks and unused scaffolding.

Keep useful tests, diagnostic tools, and documentation.

Do not run automated formatters or autofixers.

Commit the completed, verified changes locally in logical commits, following repository instructions. Do not push.

Provide a final concise implementation report containing:

1. What was implemented.
2. The exact Make commands available.
3. The Asterinas commit and build/toolchain identity.
4. The files and modules added or changed.
5. The resulting image and kernel artifact locations.
6. The actual Firecracker guest test result.
7. The executed regression-test commands and outcomes.
8. Any remaining precisely characterized compatibility limitations.
9. Commit hashes.

Do not claim completion unless the required boot and guest-test gates have actually passed.

## Definition of done

The task is complete when all of the following are true:

- `make asterinas-build` creates a verified, immutable Asterinas + Laputa system bundle.
- `make asterinas-test` boots that system in Firecracker using KVM.
- The guest runs the **native Asterinas kernel**, not Linux.
- The guest runs the **real Laputa userspace**, not NixOS or a BusyBox demonstration.
- The root filesystem is a valid ext2 image populated from Laputa's package manager.
- The initramfs successfully transitions to the persistent Laputa root.
- `xinit` runs as PID 1.
- XSH actually executes and passes the required guest functional tests.
- The interactive boot target provides a usable XSH development environment.
- Test failures return nonzero status and preserve actionable diagnostics.
- Warm builds avoid rebuilding unrelated artifacts.
- Existing Linux/QEMU functionality is preserved.
- All relevant checks and tests have passed.
- The implementation is documented and committed locally.

**Do not deliver a design proposal or partial implementation in place of this result. Build the system, boot it, test it, fix failures, and verify it end to end.**

The governing architectural principle is simple:

**One Laputa distribution. Two kernels. One package manager. One immutable-generation model. No Nix, no systemd, no unnecessary machinery.**
