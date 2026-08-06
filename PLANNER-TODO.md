# XSH Linux Kbuild Planner TODO

## Context

The installer work introduced an amd64 `linux-virt-amd64` package intended to
replace the large general amd64 kernel in installer images. The initial plan was
to use Alpine's `linux-virt` x86_64 config as a fast path, then prove the
result with `installer-qemu-test.xsh` before building and uploading a package.

Using Alpine's config was the right shortcut for feature selection, but it
exposed a weakness in our XSH Linux kbuild planner. Upstream kbuild carries
selection state through parent Makefile edges. Our planner often scans selected
directories too broadly, then treats local `obj-y` entries as globally active
even when the parent directory was only supposed to be entered under a disabled
config symbol.

That means disabled feature subtrees can still produce compile tasks. The
result is a stream of failures from features that are not needed by the
installer kernel and should not have been compiled at all.

## Current Symptom Pattern

The failures are not primarily QEMU boot failures. They are planner fidelity
failures.

Examples seen while trying to build `linux-virt-amd64`:

- `arch/x86/xen/enlighten.o` was compiled with `CONFIG_XEN=n`.
  `arch/x86/xen/Makefile` has unconditional local `obj-y` entries, but upstream
  kbuild only reaches that directory through a parent Xen gate.
- `arch/x86/hyperv/hv_crash.o` was compiled from Alpine's broader cloud VM
  config surface. It required companion crash assembly symbols that were not
  present in our generated build path.
- `arch/x86/kernel/crash.o` remained planned after `CONFIG_CRASH_DUMP=n`
  because related kexec/crash symbols and stale plan entries still pulled crash
  objects into the build.
- `arch/x86/kernel/kvm.o` required static-call declarations for KVM guest
  support that our builder was not generating. KVM guest enlightenments are not
  required for the QEMU installer kernel.
- Enabling `CONFIG_CC_HAS_NAMED_AS` / `CONFIG_USE_X86_SEG_SUPPORT` exposed a
  Clang/static-initializer failure in x86 percpu code. That one is more of a
  config/toolchain interaction, but it appeared during the same iteration loop.

The short-term package changes have been to trim the installer kernel config to
the minimal QEMU surface and add targeted stale-plan skips. Those unblock
installer iteration, but they are not the right long-term planner architecture.

## Short-Term Installer Path

Keep the installer proof moving by trimming `linux-virt-amd64` to the boot
surface needed by QEMU:

- built in: serial console, PCI, virtio, virtio PCI/MMIO, virtio block, virtio
  net, ext4, devtmpfs/initrd/root mount basics
- disabled: Xen, Hyper-V, kexec/crash, KVM guest enlightenments, tracing,
  modules, and other cloud/hypervisor extras not needed for installer boot

This should be treated as an installer-kernel scope decision, not as proof that
the planner handles Alpine's full virt config.

## Continuation: Current Installer-Kernel Work

This section captures the active work state so another agent can continue
without reading the conversation history.

The active user goal is to prove the amd64 installer can boot with a smaller
`linux-virt-amd64` kernel package before building/uploading that package. The
proof target is `installer-qemu-test.xsh` in the Laputa repo, but the current
blocker is still the package build in the packages repo.

Remote amd64 iteration host:

- host: `threadripper`
- Laputa repo: `/home/josh/d/laputa-systems/laputa`
- packages repo: `/home/josh/d/laputa-systems/packages`

Relevant package files on `threadripper`:

- `/home/josh/d/laputa-systems/packages/repo/linux/kbuild.xsh`
- `/home/josh/d/laputa-systems/packages/repo/linux/PKGBUILD-x86_64.xsh`
- `/home/josh/d/laputa-systems/packages/repo/linux-virt-amd64/PKGBUILD.xsh`
- `/home/josh/d/laputa-systems/packages/repo/linux-virt-amd64/linux-virt-amd64-build.xsh`
- `/home/josh/d/laputa-systems/packages/repo/linux-virt-amd64/alpine-virt-x86_64.config`

The current `linux-virt-amd64` package uses Alpine's `linux-virt` config as a
base, then applies overrides in `linux-virt-amd64-build.xsh`. The overrides
currently keep the QEMU-relevant pieces built in and disable broad optional VM
surfaces that are not needed for installer boot.

Important overrides already added or expected:

- force built in: `BLK_DEV_INITRD`, `DEVTMPFS`, `DEVTMPFS_MOUNT`,
  `DEVTMPFS_SAFE`, `EXT4_FS`, `INET`, `NET`, `PCI`, `SERIAL_8250`,
  `SERIAL_8250_CONSOLE`, `SERIAL_8250_PCI`, `UNIX`, `VIRTIO`,
  `VIRTIO_BLK`, `VIRTIO_CONSOLE`, `VIRTIO_MENU`, `VIRTIO_MMIO`,
  `VIRTIO_NET`, `VIRTIO_PCI`, `VIRTIO_PCI_LIB`,
  `VIRTIO_PCI_LIB_LEGACY`, `VIRTIO_PCI_MODERN`,
  `VIRTIO_PCI_MODERN_DEV`, `VIRTIO_PCI_LEGACY`, `VIRTIO_RING`
- force disabled: `MODULES`, tracing/ftrace symbols, Xen symbols, Hyper-V
  symbols, crash/kexec symbols, KVM host symbols, KVM guest symbols,
  `CC_HAS_NAMED_AS`, `CC_HAS_NAMED_AS_FIXED_SANITIZERS`,
  `USE_X86_SEG_SUPPORT`
- set: `HZ=250`, `HZ_1000=n`, `CMDLINE_LOG_WRAP_IDEAL_LEN=1021`

Recent XSH kbuild support already added:

- disabled Kconfig comments are parsed as `n`
- disabled values are emitted as disabled comments in `include/config/auto.conf`
  and omitted from `include/generated/autoconf.h`
- 32-bit x86 syscall table generation emits
  `arch/x86/include/generated/asm/syscalls_32.h`
- generated package sources are prepared for unicode data, VT keymaps, console
  map tables, and ASN.1 generated crypto/asymmetric-key sources
- KVM asm offsets generation is conditional on `CONFIG_KVM=y`
- temporary stale-plan skips were added for some disabled Xen, Hyper-V,
  crash/kexec, and KVM guest objects

The most recent diagnostic failure was:

```text
make task '.xsh-kbuild/obj/arch/x86/kernel/cpu/vmware.o' failed
arch/x86/kernel/cpu/vmware.c:354: use of undeclared identifier '__SCT__pv_steal_clock'
arch/x86/kernel/cpu/vmware.c:354: use of undeclared identifier '__SCK__pv_steal_clock'
```

This is the same static-call surface previously seen in
`arch/x86/kernel/kvm.o`. For the installer kernel, VMware guest enlightenment is
not required. The likely immediate fix is to disable the config symbols that
select `arch/x86/kernel/cpu/vmware.o`, probably by disabling VMware guest
support and possibly broader `HYPERVISOR_GUEST`/paravirt guest detection if it
is only selecting optional hypervisor enlightenments. Preserve enough generic
boot support for QEMU plus virtio.

Before changing config, inspect the active `.config` and Makefile selectors in
the prepared build root:

```sh
ssh threadripper "doas sh -c 'cd /root/.cache/laputa/amd64-package-test/.set-build-root/var/tmp/pm-build/linux-virt-amd64-7.0.5-1/src && grep -E \"CONFIG_(VMWARE|HYPERVISOR|PARAVIRT|KVM_GUEST|STATIC_CALL)\" .config | head -120 && grep -n \"vmware.o\" arch/x86/kernel/cpu/Makefile arch/x86/kernel/Makefile'"
```

The direct diagnostic command used during iteration is:

```sh
ssh threadripper 'bash -lc "cd /home/josh/d/laputa-systems/packages && doas env XSH_LINUX_REAL=1 XSH_MODULE_PATH=/usr/lib/pm XSH_LINUX_KBUILD_PROGRESS=1 XSH_LINUX_KBUILD_PROGRESS_EVERY=1000 XSH_LINUX_KBUILD_JOBS=8 XSH_LINUX_KBUILD_DISCOVER_JOBS=8 /home/josh/d/laputa-systems/xsh/target/debug/xsh pm/chroot-run.xsh -- /root/.cache/laputa/amd64-package-test/.set-build-root /home/josh/d/laputa-systems/xsh/target/debug/xsh /tmp/run-linux-virt-diag.xsh"'
```

If source files are edited in the package checkout and the prepared build root
already exists, copy them into the build root before rerunning the diagnostic:

```sh
ssh threadripper 'bash -lc "cd /home/josh/d/laputa-systems/packages && doas cp repo/linux/kbuild.xsh /root/.cache/laputa/amd64-package-test/.set-build-root/var/tmp/pm-build/linux-virt-amd64-7.0.5-1/src/kbuild.xsh && doas cp repo/linux-virt-amd64/linux-virt-amd64-build.xsh /root/.cache/laputa/amd64-package-test/.set-build-root/var/tmp/pm-build/linux-virt-amd64-7.0.5-1/src/linux-virt-amd64-build.xsh && doas rm -f /root/.cache/laputa/amd64-package-test/.set-build-root/var/tmp/pm-build/linux-virt-amd64-7.0.5-1/src/.xsh-kbuild-archive-plan.json /root/.cache/laputa/amd64-package-test/.set-build-root/var/tmp/pm-build/linux-virt-amd64-7.0.5-1/src/.xsh-kbuild-archive-plan-summary.json"'
```

When the direct diagnostic passes, run the real package proof from the Laputa
repo on `threadripper`:

```sh
ssh threadripper 'bash -lc "cd /home/josh/d/laputa-systems/laputa && doas env LAPUTA_PACKAGES_ROOT=/home/josh/d/laputa-systems/packages XSH_HOST=/home/josh/d/laputa-systems/xsh/target/debug/xsh XSH_LINUX_KBUILD_PROGRESS=1 XSH_LINUX_KBUILD_PROGRESS_EVERY=1000 make amd64-package-test PKGNAME=linux-virt-amd64"'
```

After the package proof passes, find the built tarball:

```sh
ssh threadripper 'bash -lc "doas find /root/.cache/laputa/amd64-package-test -name \"linux-virt-amd64-*.tar.gz\" -ls"'
```

Then use that local tarball in the installer proof. The Laputa installer builder
may still need support for a local kernel tarball override such as
`LAPUTA_INSTALLER_KERNEL_TARBALL`, so the installer test can consume the
locally built package before upload. The desired proof shape is:

```sh
ssh threadripper 'bash -lc "cd /home/josh/d/laputa-systems/laputa && LAPUTA_INSTALLER_ARCH=x86_64 LAPUTA_INSTALLER_KERNEL_PACKAGE=linux-virt-amd64 LAPUTA_INSTALLER_KERNEL_TARBALL=/path/to/linux-virt-amd64-7.0.5-1.tar.gz ./installer-qemu-test.xsh"'
```

Do not upload or push until `installer-qemu-test.xsh` passes with the local
`linux-virt-amd64` package.

## Proper Planner Fix

The planner needs gated traversal. The key invariant should be:

> A local `obj-y` entry is only active if every parent Makefile edge that led to
> that directory is active for the current config.

Today the planner can enter a directory and then honor unconditional local
entries without preserving the parent condition. That is why disabled subtrees
leak into the archive plan.

### 1. Track Selection Gates

When parsing Makefile entries, preserve the condition that selected each item.
For example:

- `obj-$(CONFIG_XEN) += xen/` means `arch/x86/xen` is selected under
  `CONFIG_XEN=y`
- every object discovered inside `arch/x86/xen` inherits that gate
- unconditional entries inside that directory are unconditional only relative to
  the directory, not globally

Represent each planned directory/object with a gate expression or a normalized
set of required config symbols.

### 2. Gate Directory Traversal

Before scanning a child directory, evaluate the inherited gate. If it is false,
do not scan the directory at all.

This is better than scanning the directory and filtering known object names
later. Filtering requires endless local knowledge of Linux internals and misses
new subtrees.

### 3. Shrink `skip_planned_object`

The current skip hook is useful as an emergency compatibility layer, but it
should not be where parent gating semantics live.

Keep it only for exceptional generated-object quirks or temporary compatibility.
Move normal config-based inclusion/exclusion into gated traversal.

### 4. Handle Composite Objects Under Gates

Composite members must inherit the gate of the composite object. If
`foo-y += a.o b.o` is part of an object that was selected by
`obj-$(CONFIG_FOO) += foo.o`, both `a.o` and `b.o` must be gated by
`CONFIG_FOO=y`.

This matters for archive planning because composite members can otherwise show
up as compile tasks even when the top-level object should be absent.

### 5. Add a Planner Audit Mode

Add a report mode that can explain why an object is present. For each planned
object, emit:

- object path
- source Makefile path
- parent directory chain
- config gate chain
- final evaluated active/inactive status

This would have made the Xen and Hyper-V mistakes immediately obvious.

Example output shape:

```text
arch/x86/xen/enlighten.o
  selected by: arch/x86/xen/Makefile obj-y += enlighten.o
  parent gate: arch/x86/Makefile obj-$(CONFIG_XEN) += xen/
  active: false
```

### 6. Add Regression Fixtures

Add small planner tests or fixtures that lock in the behavior before touching
the full kernel build. Minimum cases:

- `arch/x86/xen` with `CONFIG_XEN=n` must not produce Xen objects
- `arch/x86/hyperv` with `CONFIG_HYPERV=n` must not produce Hyper-V objects
- `arch/x86/kernel/crash.o` with `CONFIG_CRASH_DUMP=n` must not be planned
- `arch/x86/kernel/kvm.o` with `CONFIG_KVM_GUEST=n` must not be planned
- a composite object selected by `obj-$(CONFIG_FOO)` must gate all composite
  members

These tests should run without a full kernel compile.

## Implementation Notes

Likely files in the package repo:

- `~/d/laputa-systems/packages/repo/linux/kbuild.xsh`
- `~/d/laputa-systems/packages/repo/linux/PKGBUILD-x86_64.xsh`
- `~/d/laputa-systems/packages/repo/linux-virt-amd64/`

The Laputa repo uses the package repo through `LAPUTA_PACKAGES_ROOT`. The amd64
iteration host is `threadripper`, where the relevant package checkout is usually
`/home/josh/d/laputa-systems/packages`.

When proving planner changes, prefer a planner-only test first. Then run the
targeted `linux-virt-amd64` package build. Only after that use the resulting
package in `installer-qemu-test.xsh`.

## Success Criteria

- Disabled parent-gated subtrees are not scanned or planned.
- The planner can explain why each object was included.
- The regression fixtures above pass without a full kernel compile.
- `linux-virt-amd64` no longer needs a growing list of stale-plan object skips
  for ordinary config-gated Linux subtrees.
- The installer proof can focus on actual boot behavior instead of discovering
  planner leaks one optional subsystem at a time.
