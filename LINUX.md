# Linux Package

This document is the operating guide for the Laputa `linux` package. It
covers the native XSH Kbuild path, the package proof gates, local iteration
commands, and the amd64 completion criteria.

## Status

The `linux` package is the source of:

- `/boot/vmlinuz`
- kernel UAPI headers under `/usr/include`
- the packaged config at `/usr/share/linux/config-7.0.5`

The package is intentionally built through Laputa PM and the XSH-native Kbuild
implementation. Upstream `make` may be used as an oracle while debugging flags,
generated inputs, object membership, or link order, but it is not the package
build system.

Current package identity:

- package: `linux`
- kernel: `7.0.5`
- release: `30`
- architectures: `aarch64` and `x86_64`

The amd64 path is proved on `threadripper` through the top-level
`linux-amd64-*` helpers. Those helpers run the XSH-native Kbuild path through
Laputa PM, normalize logs under `/tmp/laputa-linux-amd64-*.log`, and treat
intentional stopped-stage markers as successful partial proofs. Verify the
exact local or mirror tarball before treating any older artifact as equivalent
to the current package metadata.

## Package Layout

- `~/d/laputa-systems/packages/repo/linux/PKGBUILD.xsh`: PM-facing package entrypoint, metadata,
  source list, arch dispatch, install layout, and proof handoff.
- `~/d/laputa-systems/packages/repo/linux/PKGBUILD-shared.xsh`: shared prepare, install, job-count,
  and package helpers.
- `~/d/laputa-systems/packages/repo/linux/PKGBUILD-aarch64.xsh`: arm64 native Kbuild package path.
- `~/d/laputa-systems/packages/repo/linux/PKGBUILD-x86_64.xsh`: x86_64 native Kbuild package path.
- `~/d/laputa-systems/packages/repo/linux/kbuild-pool-worker.xsh`: process-pool worker for uncached local-record discovery.
- `~/d/laputa-systems/packages/repo/linux/linux_config.xsh`: native config-fragment writer.
- `~/d/laputa-systems/packages/repo/linux/kbuild.xsh`: XSH-native selected Kbuild implementation.
- `linux-iteration.xsh`: local amd64 iteration helper for config,
  stopped-stage proofs, source-to-object probes, cache reports, and normalized
  logs.
- `~/d/laputa-systems/packages/repo/linux/files/config/aarch64/base-aarch64.fragment`: arm64 base
  package config fragment.
- `~/d/laputa-systems/packages/repo/linux/files/config/x86_64/base-x86_64.fragment`: amd64 base
  package config fragment.
- `~/d/laputa-systems/packages/repo/linux/proof.xsh`: package content proof.
- `~/d/laputa-systems/packages/repo/linux/tests/`: package-local test helpers.

`PKGBUILD.xsh` must remain the PM entrypoint. Keep arch-specific logic in the
split arch files and shared logic in `PKGBUILD-shared.xsh`. The underscore
`PKGBUILD_aarch64.xsh`, `PKGBUILD_x86_64.xsh`, and `PKGBUILD_shared.xsh` names
are import-compatible links to the hyphenated files.

## Config Fragment Model

Linux config input is arch-specific and fragment based. `PKGBUILD.xsh` selects
the package arch, maps it to the Linux `SRCARCH`, resolves that arch's fragment
list, and writes `.config` through `linux_config.xsh` before parser generation
or native Kbuild starts.

The current `base-*.fragment` files are intentionally complete base configs
copied from the previous package configs. This first step changes the package
structure without changing kernel intent. Smaller feature overlays can be added
later, but only after the native merge path is fast and has a proof that
overrides are deterministic.

`linux_config.xsh` currently uses a complete-fragment fast path. A native
Kconfig-aware resolver for `select`, defaults, dependencies, and choices is
still a follow-up. Do not hide an unproven resolver in the package build path:
the failed prototype was both too broad, because it read non-target arch
Kconfig files and help text, and too slow, because parsed full-config merging
took about 24 seconds for the amd64 config before Kbuild even started. The
accepted package path generated the complete amd64 config in about 0.09 seconds.

The current amd64 config-fragment refactor proof on `threadripper` is:

```sh
make linux-amd64-prepare-proof
```

This run reached the explicit stop marker:

```text
error: linux-kbuild-stopped: stopped after prepare
```

The generated `.config` had no added `=y` symbols compared with
`files/config/x86_64/base-x86_64.fragment`, and no bogus cross-arch or
help-text symbols such as `CONFIG_RISCV_*`, `CONFIG_ARC_*`, `CONFIG_the`, or
`CONFIG_it`.

For a fast config-only proof, use:

```sh
make linux-amd64-kconfig-proof
```

This writes `/tmp/laputa-linux-amd64.config`, verifies that the generated
complete-fragment config did not add `=y` symbols relative to the amd64 base
fragment, and rejects the known bogus cross-arch/help-text symbols.

## Invariants

Do not make the Linux package pass by deleting selected upstream sources,
removing critical subsystems, or replacing upstream x86 headers with semantic
stubs. Missing selected sources are build failures, not cleanup opportunities.

The amd64 product profile requires real coverage for KVM host, KVM guest,
paravirt, hypervisor guest, x86 MM, scheduler, ACPI, APIC, PCI/EFI, virtio,
filesystems, nftables/netfilter, cgroups/memcg, namespaces, laptop hardware
support, and the x86 boot/compressed path unless a deliberate product profile
decision removes that feature from the config.

Every complete amd64 package proof must preserve at least these gate objects in
the selected archive plan and compiled object tree:

- `arch/x86/kernel/cpu/hypervisor.o`
- `arch/x86/kernel/cpu/vmware.o`
- `arch/x86/kernel/cpu/mshyperv.o`
- `arch/x86/kernel/kvm.o`
- `arch/x86/kernel/kvmclock.o`
- `arch/x86/kernel/pvclock.o`
- `arch/x86/kernel/paravirt.o`
- `arch/x86/kernel/paravirt-spinlocks.o`
- `mm/vmstat.o`
- `arch/x86/kvm/vmx/main.o`
- `arch/x86/kvm/svm/svm.o`
- `kernel/fork.o`
- `mm/memcontrol.o`
- `net/netfilter/nf_tables_api.o`
- `net/ipv4/netfilter/nf_socket_ipv4.o`
- `net/ipv6/netfilter/nf_socket_ipv6.o`
- `crypto/ecc.o`
- `crypto/ecdh.o`
- `drivers/gpu/drm/drm_drv.o`
- `sound/core/seq_device.o`

The installed amd64 `/boot/vmlinuz` must be a real x86 boot image. The proof
checks the `MZ` header at byte 0 and the `HdrS` boot-protocol marker at offset
`0x202`. A raw `vmlinux` binary copied to `arch/x86/boot/bzImage` is not a
valid package result.

## Threadripper Environment

The amd64 iteration host is `threadripper`:

```sh
ssh -tt threadripper bash
cd /home/josh/d/laputa-systems/laputa
```

If the remote login shell reports that `bash` could not be executed, run
`bash` at the remote prompt. Cargo is not on the default remote `PATH`; use
`/home/josh/.cargo/bin`. For local XSH builds on that host, use the debug
binary unless explicitly proving a published XSH release. For routine
type-checking, the plain dev build is enough:

```sh
/home/josh/.cargo/bin/cargo build
```

For the current high-throughput Linux proof loop, keep the debug binary built
with optimized dev settings. This is still a dev-profile build, not a release
binary:

```sh
CARGO_PROFILE_DEV_OPT_LEVEL=2 CARGO_PROFILE_DEV_DEBUG=0 \
  /home/josh/.cargo/bin/cargo build --bin xsh
```

Useful environment for Linux package work on `threadripper`:

```sh
PATH=/home/josh/.cargo/bin:/usr/bin:/bin
XSH_HOST=/home/josh/d/laputa-systems/xsh/target/debug/xsh
MAKEFLAGS=-j32
XSH_LINUX_KBUILD_JOBS=32
```

Do not build release XSH binaries for routine iteration.

## Normal Proof Commands

Run package builds from the repository root through the top-level `Makefile`.
For amd64 iteration on `threadripper`, prefer the `linux-amd64-*` helper
targets first; they normalize logs and treat intentional stop markers as
successful proofs.

Arm64 package proof:

```sh
make package-test PKGNAME=linux
```

Amd64 package proof on `threadripper`:

```sh
make linux-amd64-package-proof
```

Amd64 package proof using a trusted current plan and archive plan, but still
rebuilding package outputs instead of targeting one object:

```sh
doas env \
  PATH=/home/josh/.cargo/bin:/usr/bin:/bin \
  MAKEFLAGS=-j32 \
  XSH_LINUX_KBUILD_JOBS=32 \
  XSH_HOST=/home/josh/d/laputa-systems/xsh/target/debug/xsh \
  XSH_LINUX_KBUILD_TRUST_PLAN_CACHE=1 \
  XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN=1 \
  make amd64-package-test PKGNAME=linux
```

Do not count a run with `XSH_LINUX_KBUILD_ONLY=...` as package success. Those
runs are compile probes. Do not count `linux-native-kbuild-complete` alone as
amd64 boot-image success; the package proof and QEMU smoke must also pass.

Boot the exact local amd64 package tarball produced by the package proof:

```sh
doas env \
  XSH_BOOT_KERNEL_PACKAGE=/root/.cache/laputa/amd64-package-test/.out/linux-7.0.5-30.tar.gz \
  XSH_LINUX_LOOP_TIMEOUT=120 \
  PATH=/home/josh/.cargo/bin:/usr/bin:/bin \
  XSH_HOST=/home/josh/d/laputa-systems/xsh/target/debug/xsh \
  make world-smoke-amd64
```

The package helper writes the full PM/Kbuild log to
`/tmp/laputa-linux-amd64-package.log` and prints the elapsed wall time on
success. The expected successful package log includes plan/archive-plan cache
status, `linux-native-kbuild-complete`, `linux proof ok`, and a built package
line for the current release.

Linux build logs also include `linux-kbuild-timing-done` records when
`XSH_LINUX_KBUILD_TIMING=1` (the world-build and amd64 package-test helpers
enable this by default). Records report elapsed milliseconds for package-total,
config, parser generation, native Kbuild, and package assembly, with nested Kbuild
records for prepare, discovery, planning, compilation, linking, arm64 NVHE,
and archive-plan construction. Set `XSH_LINUX_KBUILD_TIMING=0` to suppress
these records.

## Stage Stops And Targeted Probes

Use the helper targets to stop before expensive phases while tuning planning or
discovery. Each target writes a normalized log in `/tmp` and reports the
overall elapsed wall time from `linux-iteration.xsh`:

```sh
make linux-amd64-prepare-proof
make linux-amd64-discover-proof
make linux-amd64-plan-proof
make linux-amd64-compile-proof
make linux-amd64-link-proof
```

The package build also emits opt-in phase markers when the helper sets
`XSH_LINUX_KBUILD_TIMING=1`:

```text
linux-kbuild-timing-start prepare
linux-kbuild-timing-done prepare 1234ms
```

The `timing-done` record reports the elapsed wall time for the phase. The
timing API is opt-in at the package level, but the world-build and amd64
package-test helpers enable it by default.

For macOS arm64, use the package-test path. It runs the package manager in the
arm64 Docker environment and uses the checked-out package and XSH sources:

```sh
make package-deps-test PKGNAME=linux
make linux-plan-only PKGNAME=linux
make package-test PKGNAME=linux
```

`linux-plan-only` intentionally stops after Kbuild planning and treats the
stop status as success. Use it to measure discovery and planning without
compiling kernel objects. Uncached local-record discovery always uses the
process pool; workers run `/bin/xsh` inside the package-build chroot. The
process pool preserves deterministic plan ordering after workers finish.

For a source-warm, dependency-warm cold planner measurement, bypass the
discovery, compile-flags, and archive-plan caches:

```sh
make linux-plan-only PKGNAME=linux \
  XSH_LINUX_KBUILD_LOCAL_RECORDS=1 \
  XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE=0 \
  XSH_LINUX_KBUILD_FORCE_DISCOVER=1 \
  XSH_LINUX_KBUILD_FORCE_ARCHIVES=1 \
  XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN=0 \
  XSH_LINUX_KBUILD_DISCOVER_JOBS=16
```

For a genuinely cold end-to-end arm64 run, remove the Linux-specific
package-test volumes before `make package-test PKGNAME=linux`:

```sh
docker volume rm \
  laputa-package-test-cache-aarch64 \
  laputa-package-test-work-aarch64 \
  laputa-package-test-set-root-aarch64 \
  laputa-package-test-set-build-root-aarch64 \
  laputa-package-test-source-mirrors-aarch64
make package-test PKGNAME=linux
```

All Docker package and world-build inputs are named volumes. Make targets
refresh the checked-out packages and XSH core sources into those volumes before
running; override `DOCKER_VOLUME_PREFIX` when separate volume namespaces are
needed.

The end-to-end timing includes source mirror fetch, source extraction, source
copy, dependency setup, Kbuild planning, compilation, linking, installation,
and package proof. The source extraction step is expected to be slow across
the macOS Docker filesystem; report it separately from Kbuild timing when
comparing planner changes.

The 2026-07-14 cold arm64 package test completed successfully in 361.46s. Its
recorded boundaries were approximately 117.9s for source preparation, 176.5s
for Kbuild, 167.8s for compilation, 3.5s for linking, and 0.7s for install;
the package proof reported `linux ok` and produced the `linux-7.0.5-34`
package. These figures include the macOS Docker filesystem cost and are a
whole-package baseline, not a pure planner target.

The arm64 planner's semantic oracle is separate from `linux-plan-only`. It
compares the discovered object graph, composite relationships, archive
membership, materialized generated outputs, and upstream Kbuild dry-run
relationships. Run it with explicit paths to the matching source tree,
config, discovered plan, archive plan, and upstream dry-run capture:

```sh
make linux-kbuild-oracle \
  LINUX_ORACLE_XSH_PLAN=/path/to/.xsh-kbuild-plan.json \
  LINUX_ORACLE_XSH_ARCHIVE_PLAN=/path/to/.xsh-kbuild-archive-plan.json \
  LINUX_ORACLE_SOURCE_ROOT=/path/to/linux-source \
  LINUX_ORACLE_CONFIG=/path/to/linux-source/.config \
  LINUX_ORACLE_MATERIALIZED_MANIFEST=/path/to/linux-source/.xsh-kbuild/materialized-outputs \
  LINUX_ORACLE_UPSTREAM_DRY_RUN=/path/to/upstream-make-n.txt
```

The checked-in arm64 oracle fixture is
`tools/fixtures/linux-kbuild-oracle-aarch64.json`. Refresh it only when the
matching Linux source, configuration, generated prerequisites, and upstream
dry-run capture have changed together.

Build planned objects by source file after a valid archive plan exists:

```sh
make linux-amd64-sources LINUX_SOURCES="mm/vmstat.c arch/x86/kernel/kvm.c"
make linux-amd64-object LINUX_SOURCES="mm/vmstat.c arch/x86/kernel/kvm.c"
```

`linux-amd64-sources` only reports source-to-output mapping. `linux-amd64-object`
sets `XSH_LINUX_KBUILD_ONLY` to the mapped archive-plan outputs and runs the
targeted compile probe. If `LINUX_SOURCES` is omitted, the helper uses a small
default set of high-value x86 sources including `mm/vmstat.c`,
`arch/x86/kernel/kvm.c`, `arch/x86/kernel/paravirt.c`,
`arch/x86/kvm/vmx/main.c`, and `arch/x86/kvm/svm/svm.c`.

Do not count targeted object probes as package success. Use explicit inline or
text plans only for focused compile probes; they are not complete package proofs
because they do not prove the full selected object graph.

## Cache Strategy

Upstream Linux Kbuild has incremental behavior through persistent build trees
and `.cmd` files. Laputa does not run upstream `make` as the package builder,
but the XSH-native package path has useful cache layers:

- discovered plan: `linux-x86.plan.json` and `.xsh-kbuild-plan.json` or the
  equivalent line-oriented plan format
- archive plan: `.xsh-kbuild-archive-plan.json`
- compile-flag plan:
  `/var/cache/laputa/linux-kbuild/linux-x86.compile-flags.json` and the local
  `.xsh-kbuild-compile-flags.json` fallback
- object tree outputs, depfiles, and command-signature stamps under
  `.xsh-kbuild/obj`

The current amd64 package-test build source and cache state can be inspected
with:

```sh
make linux-amd64-cache
```

The helper reports the latest `linux-<ver>-<rel>/src` tree under
`$HOME/.cache/laputa/amd64-package-test/.set-build-root/var/tmp/pm-build`,
hashes `.config`, `.xsh-kbuild-plan.json`, `.xsh-kbuild-plan.fingerprint`, and
`.xsh-kbuild-archive-plan.json`, counts existing `.xsh-kbuild/obj` outputs and
command stamps, and reports archive-plan task/archive/generated/missing counts.

For a healthy warm plan cache, the plan-stage log should report an
`xsh-kbuild-plan-cache` hit, an archive-plan cache or summary cache, and the
explicit stop marker `linux-kbuild-stopped: stopped after plan`.

The package-test PM cache at
`$HOME/.cache/laputa/amd64-package-test/.work/.chroot-build-cache/linux`
preserves the source plan, compile-flags cache, archive plan, archive-plan
summary, and fingerprints across package-test root rebuilds. That cache is the
important warm-iteration path; `/var/cache/laputa/linux-kbuild` inside the
chroot is useful while a build root exists but is not by itself stable across
`amd64-package-test` root recreation.

After a local package proof, `make linux-amd64-cache` should report a populated
archive-plan cache with no generated-source gaps and no missing sources. The
artifact proof should compile and link the selected object tree; required gate
objects such as `mm/vmstat.o`, `arch/x86/kernel/kvm.o`,
`arch/x86/kvm/vmx/main.o`, `arch/x86/kvm/svm/svm.o`, `mm/memcontrol.o`,
`net/netfilter/nf_tables_api.o`, `crypto/ecdh.o`, `drivers/gpu/drm/drm_drv.o`,
and `sound/core/seq_device.o` should be present under `.xsh-kbuild/obj`.

Use caches deliberately:

- If config, source membership, Kbuild discovery, root variables, package source
  copying, or planner logic changed, regenerate the discovered plan and archive
  plan before trusting targeted probes.
- If only generated-header parsing or compile flags changed, keep the plan but
  delete the affected object outputs or their `*.cmd` stamps.
- If selected sources were restored after a previous archive plan recorded them
  as missing, discard `.xsh-kbuild-archive-plan.json` once.
- Do not use `XSH_LINUX_KBUILD_REUSE_ARCHIVES=1` for the validation run after
  source-prep, generated input, config, core arch header, boot-image, or object
  postprocessing changes.
- `XSH_LINUX_KBUILD_REUSE_ARCHIVES=1` is only a local preserved-tree
  optimization. It is not a portable kernel object cache and it is not a final
  proof mode.
- On a fresh amd64 host, prefer a downloaded seed plan/archive-plan pair keyed
  by kernel version, config hash, package script hash, and planner version over
  rediscovering repeatedly. After any key input changes, invalidate the seed.

Force rediscovery after Kbuild or config edits:

```sh
doas rm -f \
  /root/.cache/laputa/amd64-package-test/.work/.chroot-build-cache/linux/.xsh-kbuild-plan.json \
  /root/.cache/laputa/amd64-package-test/.work/.chroot-build-cache/linux/.xsh-kbuild-plan.fingerprint \
  /root/.cache/laputa/amd64-package-test/.work/.chroot-build-cache/linux/.xsh-kbuild-archive-plan.json \
  /root/.cache/laputa/amd64-package-test/.work/.chroot-build-cache/linux/.xsh-kbuild-archive-plan.json.summary \
  /root/.cache/laputa/amd64-package-test/.work/.chroot-build-cache/linux/.xsh-kbuild-archive-plan.fingerprint \
  /root/.cache/laputa/amd64-package-test/.work/.chroot-build-cache/linux/.xsh-kbuild-compile-flags.json

doas env \
  PATH=/home/josh/.cargo/bin:/usr/bin:/bin \
  XSH_HOST=/home/josh/d/laputa-systems/xsh/target/debug/xsh \
  XSH_LINUX_KBUILD_DISCOVER_JOBS=1 \
  XSH_LINUX_KBUILD_FORCE_ARCHIVES=1 \
  XSH_LINUX_KBUILD_STOP_AFTER=plan \
  make amd64-package-test PKGNAME=linux
```

## Parallelism

Linux package builds should use all available cores for broad compile and
archive work. `PKGBUILD-shared.xsh` resolves the Kbuild job count in this
order:

1. `XSH_LINUX_KBUILD_JOBS`
2. `MAKEFLAGS` `-j` / `--jobs`
3. `cpu.count()`

On `threadripper`, set both `MAKEFLAGS=-j32` and
`XSH_LINUX_KBUILD_JOBS=32`. The `linux-amd64-*` helpers set these from
`LINUX_KBUILD_JOBS` and pass them through to the package build. The package log
should show that the native XSH make runner received the expected job count and
started the dynamic ready queue.

The dynamic scheduler removes the previous layer barrier. It
uses XSH `process.wait_ready` to reap whichever child processes have completed,
updates dependent readiness, and refills open worker slots before the next wait.
The scheduler proof in `/tmp/laputa-scheduler-proof.xsh` verifies this behavior
with a fast dependency chain and a slow independent task: the dependent
`after-fast` task is spawned before the slow independent task completes.

This still does not guarantee perfect host saturation. If compile occupancy is
poor while the archive graph has enough queued work, investigate XSH
runtime/task-turnover and child reaping overhead before lowering the package job
count or deleting kernel work.

The final accepted scheduler/cache work moved command-signature JSON
construction out of the spawn/refill path, deferred stamp writes until
`run_tasks` exits, reduced `process.wait_ready` idle polling to 1ms, suppressed
the noisy x86 `nocf_check` Clang warning, and fixed compile-flags cache JSON
round-tripping with `linux-kbuild-compile-flags-v2`. Those changes passed type
checks, the scheduler proof, a warm compile proof, and the final amd64 package
proof.

`kbuild.xsh` also parallelizes targeted source-plan refresh with `planner_jobs()`,
so the x86 targeted repair path now uses the full host CPU count instead of
the old 8-job cap.

## Mirror Verification

Before counting a downloaded amd64 artifact as complete, inspect the exact
mirror tarball:

```sh
mkdir -p /tmp/laputa-linux-amd64-inspect
curl -fL https://laputa.17166969.xyz/packages/x86_64/linux/linux-7.0.5-30.tar.gz \
  -o /tmp/laputa-linux-amd64-inspect/linux-7.0.5-30.tar.gz
tar -xzf /tmp/laputa-linux-amd64-inspect/linux-7.0.5-30.tar.gz \
  -C /tmp/laputa-linux-amd64-inspect
file /tmp/laputa-linux-amd64-inspect/boot/vmlinuz
rg 'CONFIG_X86_64|CONFIG_ARM64|CONFIG_VIRTUALIZATION|CONFIG_KVM|CONFIG_KVM_GUEST|CONFIG_PARAVIRT|CONFIG_HYPERVISOR_GUEST|CONFIG_JUMP_LABEL' \
  /tmp/laputa-linux-amd64-inspect/usr/share/linux/config-7.0.5
```

Expected amd64 package config includes:

- `CONFIG_X86_64=y`
- `CONFIG_HYPERVISOR_GUEST=y`
- `CONFIG_PARAVIRT=y`
- `CONFIG_KVM_GUEST=y`
- `CONFIG_PARAVIRT_CLOCK=y`
- `CONFIG_KVM=y`
- `CONFIG_KVM_INTEL=y`
- `CONFIG_KVM_AMD=y`
- `# CONFIG_JUMP_LABEL is not set`

If the fetch redirects to a missing object or an older invalid tarball, verify
from the local `threadripper` artifact and fix the mirror publish path
separately.

Mirror verification should fetch the public `index.json`, confirm that the
amd64 Linux entry points at the current release tarball, download that tarball,
and verify the x86 boot-image markers:

```text
MZ at byte 0
HdrS at offset 0x202
```

The downloaded package config includes `CONFIG_X86_64=y`, `CONFIG_KVM=y`,
`CONFIG_KVM_INTEL=y`, `CONFIG_KVM_AMD=y`, `CONFIG_MEMCG=y`,
`CONFIG_NAMESPACES=y`, `CONFIG_NF_TABLES=y`, `CONFIG_DRM=y`,
`CONFIG_CRYPTO_ECC=y`, and `CONFIG_CRYPTO_ECDH=y`.

## Failure Triage

Classify failures before changing code:

- Missing generated header: add the generator, translate a small generator to
  XSH, or vendor a checked generated file with a clear source.
- Wrong object membership: fix discovery or adjust the package config. Do not
  hide the problem by deleting source files.
- Wrong compile or assembly flags: compare against upstream `make V=1` and add
  the narrow flag behavior to `kbuild.xsh`.
- Unsupported assembler feature: fix flags first, then consider a packaged GNU
  binutils dependency if LLVM IAS cannot match upstream behavior.
- Link-order or archive-order mismatch: compare upstream `.cmd` files and fix
  archive planning, not source membership.
- Boot-image failure: inspect the x86 `arch/x86/boot` stages and the packaged
  `/boot/vmlinuz` headers before debugging QEMU.

Keep changes scoped under `~/d/laputa-systems/packages/repo/linux/` unless shared PM behavior is
genuinely required.

## Non-Goals

- Do not add upstream `make`, mounted host tools, or shell compatibility
  fallbacks to make the package pass.
- Do not publish a kernel that lacks selected entry, setup, APIC, MM, ACPI,
  scheduler, crypto, KVM/paravirt, or boot/compressed code.
- Do not overwrite upstream x86 headers with semantic stubs.
- Do not treat targeted object probes, inline-plan probes, or archive reuse as
  final package proofs.
