# QEMU Proof

`qemu-dwl-foot` is the one supported profile. Its acceptance test boots the
immutable image built by `laputa build`; it does not assemble a filesystem from
a handwritten package list.

## Host requirements

On macOS install Homebrew QEMU. The aarch64 test configuration uses HVF when
available. QEMU is used only to validate the generated aarch64 image; package
construction always happens in the native `linux/arm64` Docker environment.

## Commands and outputs

```bash
cd "$HOME/d/laputa-systems/laputa"
"$XSH_HOST" laputa.xsh -- build qemu-dwl-foot --jobs 4
"$XSH_HOST" laputa.xsh -- test qemu-dwl-foot
"$XSH_HOST" laputa.xsh -- boot qemu-dwl-foot
```

`test` and `boot` first build or refresh the active `current` system bundle.
`test` is deterministic: it starts QEMU without an interactive display, uses
QMP to inject `laputa` followed by EOF exactly once, waits for the bounded
guest proof, and saves a deterministic screenshot. `boot` is the separate
interactive Cocoa-display diagnostic command.

The profile output directory is `target/laputa/qemu-dwl-foot`. Each immutable
system bundle is `builds/<system-key>/` and contains `build-plan.json`,
`generation.json`, `disk.img`, `rootfs.ext4`, and `vmlinuz`. `current` is an
atomic symlink to one complete bundle. `console.log`, `qemu.log`, and
`screenshot.ppm` are proof outputs at the profile root. Image construction
stages generation/rootfs data on the container's Linux filesystem; only a
complete verified bundle is copied atomically to the host output mount.

## Proof contract

The guest coldplugs devices, starts seatd, dwl, and foot, and emits
`LAPUTA_DWL_FOOT_PROOF_OK` only after foot launches. A passing test requires
that marker and a nonempty screenshot. It rejects `Kernel panic`, `not
syncing`, and `LAPUTA_DWL_FOOT_PROOF_FAILED`; inspect `console.log` and
`qemu.log` first when it fails.

QMP retry, timeout, TERM/KILL escalation, final console-marker scan, and
screenshot presence are all supervisor-owned behaviors. The profile overlay
digest is bound into the generated image so a guest proof cannot accidentally
validate a different root generation.

Browsers, real hardware, and non-aarch64 profiles are intentionally outside
this focused proof surface.
