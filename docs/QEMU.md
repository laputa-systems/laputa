# QEMU Proof

`qemu-dwl-foot` is the one supported profile. Its acceptance test boots the
immutable image built by `laputa build`; it does not assemble a filesystem from
a handwritten package list.

## Host targets

The profile CLI runs natively on the host: it builds the image in Docker for
the host's architecture and boots it with hardware acceleration. The host
decides the QEMU target (`system/qemu.xsh`); the profile holds only system
intent.

| Host | QEMU | Machine | Console | Root disk | Interactive display |
|---|---|---|---|---|---|
| macOS aarch64 | `qemu-system-aarch64` | `virt`, HVF | PL011 `ttyAMA0` | `virtio-blk-device` | Cocoa |
| Linux aarch64 | `qemu-system-aarch64` | `virt`, KVM | PL011 `ttyAMA0` | `virtio-blk-device` | QEMU's default |
| Linux x86_64 | `qemu-system-x86_64` | `q35`, KVM, `-vga none` | 16550 `ttyS0` | `virtio-blk-pci` | QEMU's default |

On x86_64, `-vga none` removes q35's default VGA adapter so the virtio GPU is
the only display; otherwise QMP's screendump captures the VGA text console
instead of the compositor.

## Host requirements

- `qemu-system-<arch>` for the host's architecture on `PATH`, or named by
  `QEMU_SYSTEM_AARCH64` or `QEMU_SYSTEM_X86_64`. On macOS, Homebrew's `qemu`.
- KVM on Linux: `/dev/kvm` must be usable by your user.
- QEMU's virtio GPU PCI device. Some distributions package device models
  separately; on Alpine install `qemu-hw-display-virtio-gpu` and
  `qemu-hw-display-virtio-gpu-pci`.
- `python3`, which runs the QMP helper `boot/qmp-proof.py`.
- `make seed` done for the host arch. The profile build needs no mirror.

## Commands and outputs

```bash
make profile-build    # laputa.xsh -- build qemu-dwl-foot
make profile-test     # laputa.xsh -- test qemu-dwl-foot
make profile-boot     # laputa.xsh -- boot qemu-dwl-foot
make profile-plan     # laputa.xsh -- plan qemu-dwl-foot
make profile-clean    # laputa.xsh -- clean qemu-dwl-foot
```

`laputa.xsh` also takes `--jobs N` (`$XSH_HOST laputa.xsh -- build
qemu-dwl-foot --jobs 4`).

- `plan` writes `target/laputa/qemu-dwl-foot/build-plan.json`. Two runs from
  clean profile output produce byte-identical plans.
- `build` resolves or builds exact package artifacts in the shared store
  `.out/artifacts/<arch>`, composes an immutable generation, and atomically
  publishes one complete system bundle under `builds/<system-key>/`. `current`
  switches to that bundle only after its plan, generation manifest, kernel,
  root filesystem, and disk image are all verified. A warm run reuses matching
  artifacts and keeps the plan digest, generation digest, and image hash.
- `test` and `boot` first build or refresh `current`. `test` is
  deterministic: it starts QEMU without a display, uses QMP to inject `laputa`
  followed by EOF exactly once, waits for the bounded guest proof, and saves a
  screenshot. Success prints exactly `laputa test qemu-dwl-foot: ok`.
- `boot` opens QEMU's interactive display with the normal dwl and foot
  session. It is a diagnostic path, not the acceptance test.
- `clean` removes only `target/laputa/qemu-dwl-foot`, never the artifact
  store. `make clean` removes all derived state.

Each bundle `builds/<system-key>/` contains `build-plan.json`,
`generation.json`, `disk.img`, `rootfs.ext4`, and `vmlinuz`. `current` is an
atomic symlink to one complete bundle. `console.log`, `qemu.log`, and
`screenshot.ppm` are proof outputs at the profile root. Image construction
stages generation and rootfs data on the container's Linux filesystem; only a
complete verified bundle is copied atomically to the host output mount.

## Proof contract

The guest coldplugs devices, starts seatd, dwl, and foot, and emits
`LAPUTA_DWL_FOOT_PROOF_OK` only after foot launches. A passing test requires
that marker and a nonempty screenshot. It rejects `Kernel panic`, `not
syncing`, and `LAPUTA_DWL_FOOT_PROOF_FAILED`; inspect `console.log` and
`qemu.log` first when it fails.

QMP retry, the 180 s proof timeout, TERM/KILL escalation, the final
console-marker scan, and screenshot presence are all supervisor-owned
behaviors. A QEMU that exits early is reported as such, not as a timeout. The
profile overlay digest is bound into the generated image so a guest proof
cannot validate a different root generation.

Browsers, real hardware, IPv6, and Wi-Fi are outside this proof.
