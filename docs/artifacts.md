# Prebuilt artifact contract (staged, not published)

The owner arranges publication and Laputa integration after review.
No release tags have been created or moved. This file stages the exact
contract so publication is mechanical: payloads, targets, pinned
inputs, provenance, and the Laputa-side obligations.

## Payloads and targets

| Payload | Source repo @ staged SHA | x86_64-musl SHA-256 | aarch64-musl SHA-256 |
|---|---|---|---|
| `doas` | doas-rs `d43bbbb` | `d218736b535a69bf9f4ac374c94d88626a9c633b777554f819e1c902eb6b1edc` (measured at `d8a6400`; delta to here is docs/tests/CI-pin only) | not built here (see constraint C1) |
| `seatd` | seatd-rs `e32d931` | `339e726d9e4607fc00c8acf974a706bb2d19e2938a98b57b4de13a844c88cfae` (measured at `62da737`; delta to here is docs/harness/CI only, no `src/`) | `810e72a4670450355898428bd0965503224ebfab6ba31c7dad1ecf10d4826c00` (same basis) |
| `mdevd`, `mdevd-coldplug` | mdevd-rs `HEAD` | `f424788a456cfd83f44742f61968fc91819bec4625b60fdd8e7877536beef57e`, `f678eda65de90e17e6449af0267e3fa33a1f54b6a1eecdd65d654b4d2911b76f` (built at `deda1fb`; delta to HEAD is docs/CI/tests only) | `03aa518233d2650f20b9501f94c67ff26ccdb91cbd88baa07bee849d8fbbd637`, `b0da5b7191d1da8d9b62266fba72fef630408fa723c3abd427c102f04ad2dd65` (same basis; user-mode `-N` smoke green) |

Full hashes: see the combined-run evidence log (`tools/check-combined.sh`
prints all four x86_64 hashes) and seatd `doc/validation.md` (both seatd
targets with sizes). All binaries are static (`DT_NEEDED` count 0, no
`INTERP`): x86_64 static-pie, aarch64 static.

## Pinned build inputs

- Toolchain `nightly-2026-09-15` plus `rust-src`/`clippy`
  (`rust-toolchain.toml` in each repo), `Cargo.lock` enforced.
- x86_64 link: container `~/.cargo` kache wrapper + mold; aarch64 link:
  `RUSTFLAGS="-Clinker=mold -Clinker-flavor=ld"` (mold links both
  targets; the container's x86_64 gcc cannot link aarch64 objects).
- No `target-cpu=native`: default generic CPU for both targets.
  CPU baseline is whatever rustc's generic `x86-64` / `aarch64`
  implies on this toolchain; nothing opts into `-march=native`.
- Rust deps: doas `libc`+`rustix`; seatd `libc`+`rustix` (+transitives
  `bitflags`, `linux-raw-sys`, `errno` via rustix); mdevd `libc` only.
  Native linked code beyond Rust: doas links the build container's
  static `libcrypt.a` (Alpine `musl-dev`; see doas `docs/upstream.md`
  "Password hash provider"). seatd/mdevd link no native crypto or
  provider libraries.
- libudev-zero consumer reference: laputa-systems fork
  `8f1d3d0624496f1c4967f18d6afaddbd552d8bce`, used unmodified
  (`tools/check-udev-consumer.sh` prefers `~/d/libudev-zero`).

## Reproducibility

Release profiles strip (`mdevd`) or ship unstripped (`doas`, `seatd`;
`strip` is a publication-packaging choice, not a code property).
Rebuilding the seatd/doas x86_64 release binaries above with the same
recipe reproduces the same hashes (verified by rebuild). The mdevd
hashes above are fresh single-recipe builds at the staged SHA;
CI must confirm them by rebuild. Recipe notes:
mdevd/seatd x86_64 and all aarch64 builds use `RUSTFLAGS="-Clinker=mold
-Clinker-flavor=ld"`, identical to the CI recipe, so those hashes have
no local-config deviation. doas x86_64 was built under the container's
`~/.cargo/config.toml` (kache wrapper, cc driver with
`-B/usr/local/libexec/mold`) because bare mold cannot resolve its
`-lcrypt`; doas aarch64 is not attempted here (C1). Canonical release
hashes must still come from CI; any mismatch against the values here
fails publication.

## Kernel / runtime prerequisites

- Linux x86_64 or aarch64; netlink (mdevd), Unix sockets + `SCM_RIGHTS`
  (seatd), setuid + shadow + `/dev/tty` + `legacy_tiocsti` sysctl
  (doas). No D-Bus, systemd, logind, elogind, polkit.
- Minimums actually exercised: Alpine virt `6.6.142-0-virt` in KVM
  guests (mdevd node creation, seatd N1/N2, doas priv guest, combined
  run). Native aarch64 hardware, physical DRM/input/VT, and hidraw
  revoke are unqualified (named constraints, not passes).

## Licenses and attribution

- mdevd: ISC; retains Laurent Bercot attribution (`AUTHORS`,
  `COPYING`, `DCO`); libudev-zero consumer test uses the pinned fork
  unmodified.
- seatd: MIT; retains Kenny Levinsen attribution. The wire protocol is
  pinned by `harness/protocol.golden` and a raw-protocol guest client;
  no C libseat client has been run against the daemon since the
  upstream sources left the repo (open gap, see seatd
  `doc/validation.md`).
- doas: MIT; upstream and packaging pins in `docs/upstream.md`.

## Which binary each qualification exercised

- mdevd: x86_64 release binaries in `check-qemu.sh` (real kernel add,
  node creation, framed output, coldplug sync) and `check-combined.sh`
  (hashes logged); aarch64 release under `qemu-aarch64` user mode
  (`-N` smoke in CI).
- seatd: x86_64 release in guest transition/shutdown modes with the
  raw-protocol client; aarch64 release under `qemu-aarch64` user mode
  (`-v` smoke in CI). The frozen protocol golden pins client-visible
  behavior (see seatd `doc/validation.md`).
- doas: x86_64 release installed setuid inside the disposable guest
  (`harness/vm-priv.sh`, all three markers); aarch64 pending (C1).
- No Rust `seatd` daemon provides `libseat.so`. doas does not replace
  `su`/`sudoedit`.

## Laputa contract (for the owner)

- Installed paths/ownership: `doas` → setuid `4755 root:root`
  (installer operation, never in the archive); `seatd` socket
  `/run/seatd.sock` `0770` via `-u`/`-g` or default restrictive mode;
  runtime dirs `/run/doas` `0700`, config `/etc/doas.conf` `640` +
  optional `/etc/doas.d/` `750` (never overwritten or deleted by
  install/rollback).
- Foreground invocation and readiness: `seatd -n <fd>` (s6-style `\n`);
  `mdevd -D <fd>` readiness before coldplug completion; `doas -C`
  for policy checks.
- Compatibility: libseat seatd-protocol clients; libudev-zero "udev"
  group consumers of mdevd's `-O 4` rebroadcast.
- Upgrade/restart/recovery/rollback: stop clients → replace daemon →
  reconnect/reopen (seatd `doc/recovery.md`); mdevd keeps last valid
  config on bad reload; doas rollback removes only the setuid binary
  and `/run/doas`, keeps admin policy and a recovery shell.
- Still supplied by the old packages, NOT these replacements:
  `su`, `sudoedit`, `libseat.so`, firmware loading, hook spawning.

## Constraints (blockers, not passes)

- C1: doas aarch64-musl cannot link in this container (no aarch64
  `libcrypt.a`; native-aarch64 Docker build per doas README is the
  supported path). No aarch64 doas execution evidence exists.
- C2: aarch64 full-system/device proof absent everywhere (user-mode
  only). Native/VT/DRM/evdev on aarch64 hardware unqualified.
- C3: hidraw revoke unqualified (restricted scope, documented).
- C4: seatd R4 single-test failure remains unclassified (documented,
  not resolved by the fixed R7 crash).
- C5: hosted CI is green on all three staged heads (doas `d43bbbb`,
  seatd `e32d931`, mdevd here): full test suites, Clippy, both musl
  release builds, and the aarch64 user-mode smoke. Privileged,
  KVM-guest, and idle-gate proofs remain local-only evidence (see
  above); CI does not cover them.
