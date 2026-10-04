# Laputa Installer

This documents the current v1 installer architecture: a compact aarch64 or
x86_64 image that installs a barebones Laputa system and can be exercised under
QEMU. Its package roots come from the local mirror, like `make root`'s, so the
world must be built and published first (`make build`, `make mirror`, `make
publish`). `qemu-dwl-foot` has a separate build and QEMU proof; it does not
supply the installer's package roots or image policy.

## Current Shape

- The primary tested installer is now a compact hybrid ISO artifact written
  directly by XSH. The raw GPT installer image path was removed; the ISO is the
  only installer artifact.
- The image contains an ESP with `EFI/BOOT/BOOTAA64.EFI` (aarch64) or
  `EFI/BOOT/BOOTX64.EFI` (x86_64), but the current QEMU
  harness boots the packaged kernel directly with `-kernel` and `-append`.
  Direct kernel boot is deliberate for v1 because UEFI fallback does not provide
  kernel `LoadOptions`.
- The installer packages the selected kernel from the checked-out PM graph.
  The default is `linux`; `LAPUTA_INSTALLER_KERNEL_PACKAGE` selects another
  package, and `LAPUTA_INSTALLER_KERNEL_SOURCE` can override only the booted
  kernel file.
- QEMU boots the selected kernel directly with deterministic `PARTUUID=` root
  selectors for the installer ISO's embedded GPT root partition and the
  installed target disk. Native `xinit` is `/init`; there is no generated early
  userspace shim in the installer harness.
- Direct root boot without a separate initramfs depends on the kernel carrying
  a tiny built-in default cpio payload that seeds `/dev/console`, `/dev/null`,
  and `/dev/root`. This is kernel build input, not a QEMU `-initrd`.
- The installer test command line boots
  `root=PARTUUID=55555555-5555-5555-5555-555555555555`. The target smoke boot
  uses `root=PARTUUID=33333333-3333-3333-3333-333333333333`.
- There is still no bootloader. The ISO includes an ESP fallback kernel, but
  standalone EFI media boot still needs a way to pass a kernel command line.
  Both kernels carry a built-in command line naming
  `root=PARTLABEL=LAPUTA_ROOT`, the installed target's root partition (a
  bootloader's arguments append to it on x86_64 and replace it on aarch64).
  The installer ISO's root partition is `LAPUTA_INSTALLER_ROOT`, so the
  built-in line does not boot the media.
- The `xinit` package installs this checkout's `xinit/xinit.xsh` as
  `/usr/bin/xinit`, with `/init` linking to it, and the `xsh` package
  installs the local XSH seed (`make seed`) for the target arch. Both reach
  the installer through the mirror like every other package. The image
  builder runs on the host's XSH (`XSH_HOST`), but target rootfs contents come
  only from PM packages.

## Entry Points

Both targets take `ARCH` (the host's by default) and `MIRROR_URL` (the
loopback mirror by default).

- `make installer-image`
  builds the CI/autoinstall ISO at
  `target/laputa-installer-ARCH/laputa-installer-ARCH.iso` and extracts the
  matching kernel for direct QEMU boot proofs.
- `make installer-qemu-test`
  boots the hybrid installer ISO with a blank 128M virtio disk, waits for
  `LAPUTA_INSTALLER_CI_OK`, then boots the installed target disk with a
  QEMU-only Dropbear/key overlay. The host generates an ed25519 keypair, SSHes
  through QEMU user-mode port forwarding as `pazu`, checks `xinit status
  dropbear`, and runs a basic `xshi` command. x86_64 runs under KVM. Logs are
  captured at `target/laputa-installer-ARCH-qemu/qemu-installer.log` and
  `target/laputa-installer-ARCH-qemu/qemu-target.log`.
  If `target/laputa-installer/local-linux-aarch64.Image` (or
  `local-linux-x86_64.bzImage`) exists, the harness passes it as
  `LAPUTA_INSTALLER_KERNEL_SOURCE`; otherwise the image builder uses the
  kernel installed from the selected kernel package.
- `make installer-qemu-manual`
  builds a non-CI image and starts interactive QEMU with stdio serial and no
  monitor, so `^C` interrupts QEMU. Inside the guest, run `setup-laputa`; for a
  CI-sized target disk, run `setup-laputa --ci`.

## Components

- `installer/`
  contains `/usr/bin/setup-laputa` and the autoinstall/static-networking boot
  hooks. `build-installer-image.xsh` installs these files directly into the
  installer and target rootfs images and adds a serial `xshi` respawn entry to
  `/etc/inittab`. Disk discovery, swap metadata, and static IPv4 setup are all
  native XSH APIs; there are no installer-specific C helper binaries. The CI
  image enables the hook with `/etc/laputa-installer/ci`.
- `laputa-pm`
  installs PM into `/usr/lib/pm` plus a `/usr/bin/pm` wrapper. PM has no
  default remote; `XSH_PM_REPO` names one.
- `laputa-fs`
  owns the native filesystem tool surface used by the installer path:
  `mkfs.vfat`, `mkfs.ext4`, and `fsck.ext4`. `mkfs.vfat` writes the tiny
  FAT16 ESP profile used by the installer.
  `mkfs.ext4` is implemented in XSH and currently writes an
  ext2-compatible 4K-block root image mountable through the kernel ext4 driver.
  `fsck.ext4` is still a minimal superblock smoke check, not a repairing
  checker.

`installer/package_roots_host.xsh` plans the union of the requested package
roots against the local mirror on the host, requires every node to be an exact
mirror artifact, imports them into a fresh store under the work tree's
`packages/`, and composes separate target, installer, and image-tools roots
from that one plan. Composition is file extraction, so it runs on the host and
no container writes into the work tree. The target root includes the selected
kernel and `sudo-rs`; the installer and tools roots contain `laputa-fs`. QEMU
smoke adds Dropbear to the target root. Installer-specific files are overlaid
after composition, so the resulting mutable image roots do not retain PM
generation receipts.

`build-installer-image.xsh` assembles the image on the host from those roots.
It creates sparse image files with native `Path.truncate`, builds a compact
target-root tarball, copies the EFI fallback
kernel into the installer payload, autosizes the installer root image from its
contents unless `LAPUTA_INSTALLER_ROOT_MB` is set, formats the installer root
through `laputa-fs` (sized from the root's block count in laputa-fs's ext4
layout), and writes a minimal hybrid ISO/GPT artifact directly with
XSH byte APIs. Its ISO9660 view exposes the selected kernel, and
its GPT view exposes the installer ext4 root partition with the same
deterministic `PARTUUID` used by the QEMU harness.
`LAPUTA_INSTALLER_JOBS` controls the PM import concurrency (default 4).

## Kernel Size

The kernel is present three times in an installer: as the ISO-visible
direct-boot kernel, as the EFI fallback kernel in the installer payload, and
as the target root's `/boot/vmlinuz`. The x86_64 kernel is monolithic for
direct root boot and builds in broad driver families such as DRM/i915 and
media tuners; its gzip-compressed bzImage is about 9.5M.

## Install Flow

`setup-laputa`:

1. Lists candidate disks with `linux.block_devices`, ordering blank disks before
   already-partitioned disks for safer manual defaults.
2. In CI mode, chooses the first disk with no existing partitions; this avoids
   hard-coding QEMU's `vda`/`vdb` order. If the deterministic CI target root
   `PARTUUID` already exists, it treats the install as complete.
   `installer/disk_selection.xsh` checks only partition directories in sysfs.
3. Otherwise prompts unless `--disk` or `--auto` is supplied.
4. Writes a GPT with ESP, swap, and root partitions using
   `linux.write_partition_table`.
5. Formats the ESP and root partitions in the guest with `mkfs.vfat` and
   `mkfs.ext4`.
6. Creates swap metadata with `linux.mkswap`.
7. Mounts the target root, extracts the compact target-root tarball, mounts the
   ESP, and installs the fallback EFI kernel files.
8. Writes target config: hostname, fstab, static networking, `pazu` user,
   passwordless wheel sudo, and autologin on the serial console (`ttyAMA0` on
   aarch64, `ttyS0` on x86_64) and `tty1`.
9. Unmounts target filesystems and asks for installer removal.

CI mode forces an 8M swap partition so the 128M test disk can work. Normal mode
uses 2x detected memory for swap and fails if the target disk is too small.

## Deliberate v1 Shortcuts

- The QEMU proof boots the hybrid ISO with direct `-kernel`/`-append`. The
  standalone firmware path is not the tested boot path yet. Standalone
  ISO media boot needs either a tiny EFI loader that passes LoadOptions, a
  real bootloader, or a kernel config choice that supplies a usable default
  command line without rebuilding for every installer iteration.
- The installer is proven under QEMU `virt` (aarch64) and `pc` with KVM
  (x86_64) only.
- Networking is brought up with the XSH `ifup` applet when present, with the
  old minimal static IPv4 parser retained only as a fallback. The installed
  system receives the installer's address/netmask/gateway where possible, with
  simple fallbacks.
- The CI smoke test uses console markers, not a richer guest-control protocol.
  Markers are written explicitly to the serial console (`ttyAMA0` or `ttyS0`,
  whichever exists) so QEMU automation does not depend on the kernel's default
  console.
- The native `mkfs.ext4` implementation deliberately supports only the Laputa
  installer/image-builder profile. It does not create an ext4 journal yet, so
  the output is closer to an ext2 revision-1 filesystem that the ext4 kernel
  driver can mount.
- `mkfs.ext4` normalizes ownership to root and mtimes to a fixed timestamp so
  native image builds are reproducible across host filesystems.

## Known Follow-ups

- Find the clean standalone EFI media boot path, likely with a tiny EFI loader,
  a real bootloader, or a kernel config choice that supplies a usable default
  command line.
- Grow `laputa-fs` from image-builder profile support into real filesystem
  tools: ext4 journal creation, journal replay, safe fsck repairs, richer FAT
  variants, and a reference harness that cross-checks native outputs against
  established tools for the supported Laputa profiles.
- Add target disk confirmation and stronger destructive-operation guardrails for
  non-CI use.
- Make static networking preserve DHCP details more accurately, including DNS.
- Continue auditing runtime dependencies across the repo. The first pass fixed
  concrete ELF misses in `cmake`, `wayland-dev`, and `sudo-rs`; broader cleanup
  should avoid treating optional plugin/dlopen edges as hard dependencies.
- Decide whether a tiny `efibootmgr` path is still needed. The current UEFI
  fallback path does not require writing NVRAM boot entries.
