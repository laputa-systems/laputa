# Laputa Installer

A compact aarch64 or x86_64 hybrid ISO, written directly by XSH, that installs
a barebones Laputa system and is exercised under QEMU. Package roots come from
the local mirror, like `make root`'s, so build and publish the world first
(`make build`, `make mirror`, `make publish`). The `qemu-dwl-foot` profile
([QEMU](QEMU.md)) shares none of this: not the package roots, not the image
policy.

## Boot model

- The image carries an ESP with `EFI/BOOT/BOOTAA64.EFI` or `BOOTX64.EFI`, but
  the harness boots the packaged kernel directly with `-kernel`/`-append`. UEFI
  fallback boot does not provide kernel `LoadOptions`, so standalone media boot
  needs a tiny EFI loader that passes them, a real bootloader, or a kernel
  default command line. There is no bootloader yet.
- The harness selects the installer root and the installed target by
  deterministic `PARTUUID=` (the installer root's is the ISO's embedded GPT
  root partition). Native `xinit` is `/init`; there is no early userspace shim.
- Root boot without an initramfs needs the kernel's built-in default cpio to
  seed `/dev/console`, `/dev/null`, and `/dev/root`. It is a kernel build
  input, not a QEMU `-initrd`.
- Both kernels carry a built-in command line naming
  `root=PARTLABEL=LAPUTA_ROOT`, the installed target's root. A bootloader's
  arguments append to it on x86_64 and replace it on aarch64. The installer
  root is `LAPUTA_INSTALLER_ROOT`, so the built-in line does not boot the media.
- The kernel package is `linux` unless `LAPUTA_INSTALLER_KERNEL_PACKAGE` names
  another; `LAPUTA_INSTALLER_KERNEL_SOURCE` overrides only the booted kernel
  file.
- Target rootfs contents come only from PM packages. `xinit` installs
  `xinit/xinit.xsh` as `/usr/bin/xinit` with `/init` linking to it, and `xsh`
  installs the local seed (`make seed`). Only the image builder runs on the
  host's XSH (`XSH_HOST`).

## Entry points

`ARCH` defaults to the host's and `MIRROR_URL` to the loopback mirror. The
manual harness is aarch64-only and receives `MIRROR_URL` as
`LAPUTA_REPO_URL`. Variables are read in `build-installer-common.xsh`,
`build-installer-image.xsh`, `installer-qemu-test.xsh`, and
`installer-qemu-manual.xsh`.

- `make installer-image` builds the CI ISO at
  `target/laputa-installer-ARCH/laputa-installer-ARCH.iso` and extracts the
  matching kernel for direct boot.
- `make installer-qemu-test` boots the ISO with a blank virtio disk sized from
  the target root, waits for `LAPUTA_INSTALLER_CI_OK`, then boots the installed
  disk with a QEMU-only Dropbear and key overlay. The host SSHes as `pazu`
  through user-mode port forwarding, checks `xinit status dropbear`, and runs
  `xsh --help`. Installed accounts log in through `/usr/bin/xsh-login`, which
  runs `-c SOURCE` with `xsh`; the default seed's `xshi` is the documented
  stub, so there is no interactive login shell. x86_64 runs under KVM. Logs:
  `target/laputa-installer-ARCH-qemu/qemu-installer.log` and `qemu-target.log`.
  If `target/laputa-installer/local-linux-aarch64.Image` (or
  `local-linux-x86_64.bzImage`) exists, it is used as
  `LAPUTA_INSTALLER_KERNEL_SOURCE`.
- `make installer-qemu-manual` is aarch64-only regardless of `ARCH`. It builds a
  non-CI image under `target/laputa-installer/` and starts QEMU with stdio
  serial and no monitor, so `^C` interrupts QEMU. In the guest run
  `setup-laputa` (`setup-laputa --ci` for a CI-sized disk). The target sets the
  XSH module path and passes `MIRROR_URL` to the image builder. The aarch64
  packages must be published to the running mirror.

## Components

- `installer/` holds `setup-laputa.xsh` and the autoinstall and static-network
  boot hooks. Disk discovery, swap metadata, and IPv4 setup are native XSH;
  there are no installer C helpers. `/etc/laputa-installer/ci` enables the CI
  hook. `build-installer-image.xsh` installs these files into the installer and
  target roots and adds a serial `xshi` respawn entry to `/etc/inittab`. The
  installer programs live in `/usr/lib/laputa-installer` behind a
  `/usr/bin/setup-laputa` wrapper, which resolves `trust.*` from laputa-pm's
  `/usr/lib/pm` because `/usr/bin/trust` is the trust command.
- `laputa-pm` installs PM into `/usr/lib/pm` with a `/usr/bin/pm` wrapper. PM has
  no default remote; `XSH_PM_REPO` names one.
- `laputa-fs` provides `mkfs.vfat`, `mkfs.ext4`, and `fsck.ext4`
  (`packages/laputa-fs/files/`). `mkfs.vfat` writes the tiny FAT16 ESP.
  `mkfs.ext4` is XSH, supports only the installer profile, and writes a
  journal-less ext2-style 4K-block root the kernel ext4 driver mounts. It
  normalizes ownership to root and mtimes to a fixed timestamp so image builds
  are reproducible. `fsck.ext4` only checks the superblock. Repair is `e2fsck` from e2fsprogs, on a detached or read-only volume.

`installer/package_roots_host.xsh` plans the union of the requested roots
against the mirror on the host, requires every node to be an exact mirror
artifact, imports them into a fresh store under the work tree's `packages/`,
and composes target, installer, and image-tools roots from that one plan.
Composition is file extraction on the host; no container writes into the work
tree. The target root adds the kernel, `doas-rs`, and `ca-certificates` (the
trust seeds the installer bootstraps from), the installer and tools
roots add `laputa-fs`, and the QEMU test adds Dropbear to the target. Installer
files are overlaid after composition, so image roots carry no PM generation
receipts. `LAPUTA_INSTALLER_JOBS` sets import concurrency (default 4).

`build-installer-image.xsh` assembles the image from those roots: sparse files
via `Path.truncate`, a compact target-root tarball, the EFI fallback kernel,
and an installer root sized from its contents (override with
`LAPUTA_INSTALLER_ROOT_MB`; `installer/rootfs_size.xsh` accounts for per-group
metadata) formatted through `laputa-fs`. It writes the hybrid ISO/GPT with XSH
byte APIs: the ISO9660 view exposes the selected kernel, the GPT view the
installer ext4 root.

## Install flow

`setup-laputa`:

1. Lists disks with `linux.block_devices`, blank disks first.
2. In CI mode, takes the first disk with no partitions (QEMU's `vda`/`vdb`
   order is not assumed) and treats the install as complete if the
   deterministic target root `PARTUUID` already exists
   (`installer/disk_selection.xsh`). Otherwise it prompts unless `--disk` or
   `--auto` is given.
3. Writes a GPT with ESP, swap, and root via `linux.write_partition_table`,
   formats ESP and root with `mkfs.vfat` and `mkfs.ext4`, and runs
   `linux.mkswap`.
4. Extracts the target-root tarball, installs the fallback EFI kernel files on
   the ESP, and writes hostname, fstab, static networking, the `pazu` user,
   passwordless wheel doas, and autologin on the serial console and `tty1`.
5. Unmounts and asks for installer removal.

CI mode forces an 8M swap partition so the 128M disk fits. Normal mode uses 2x
detected memory and fails if the disk is too small.

## Known limits

- Standalone firmware boot of the ISO is untested; the proof uses direct kernel
  boot. The harness covers QEMU `virt` (aarch64) and `pc` with KVM (x86_64); see
  [verification limits](TESTING.md) for the aarch64 gap.
- Networking runs `ifup -a` when `/usr/bin/ifup` exists; otherwise the boot hook
  parses `/etc/network/interfaces` for static IPv4 only. The installed system
  inherits the installer's address, netmask, and gateway where available.
- The CI test reads console markers written to `ttyAMA0` or `ttyS0`, whichever
  exists, so it does not depend on the kernel's default console. There is no
  richer guest-control protocol.
