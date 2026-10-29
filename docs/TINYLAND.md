# Tinyland kiosk profile

Opt-in Laputa profiles `qemu-tinyland-foot` (unbound seat) and
`qemu-tinyland-vt-foot` (VT-bound seat): unprivileged tinyland through
seatd-mediated devices, running Laputa foot. `qemu-dwl-foot` remains the
canonical reference until the owner swaps the default on the evidence below.

Non-goals: tiling, pointer/multiwindow operation, GPU rendering, general
scale/transform handling, a desktop environment, finishing Wayland protocols.

## Status

Landed on laputa master as `feat(laputa): prototype opt-in
qemu-tinyland-foot profile`:

- `packages/tinyland`: builds upstream `tinyland@e40d653` (codeload
  sha256 `3f0c43...6a`; `cargo-vendor` source over the pinned
  `Cargo.lock` (sha256 `f075...1e`). Provenance for both hashes is
  the `prerelease` workflow run on that SHA in laputa-systems/tinyland,
  plus the dispatch hangup fix re-qualified by the R3 broker-loss phase.
- `profiles/qemu-tinyland-foot` plus guest proof
  `guest/qemu-tinyland-foot-proof.xsh` and overlay session scripts under
  `profiles/qemu-tinyland-foot/usr/lib/laputa/`.
- `packages/baselayout`: `laputa` joins the `seat` group (socket access)
  and the `tty` group (pty allocation).
- Proof markers are typed profile data (`SystemProfile.proof`); the dwl
  profile keeps its exact markers, and its guest test still passes.

## Evidence

`make profile-tinyland-test` passes end to end: mdevd coldplug, unprivileged
direct-open denial for DRM and evdev, seat open through the broker, mediated
DRM/input, QMP input to the post-input magenta marker, confirmed
presentation, clean shutdown. The runtime closure is 26 packages with no
dwl, wlroots, libinput, libdrm, mesa, wayland-server, or xwayland
(vs 34 for dwl).

Gate status: 1 done; 2 done against the exact Laputa chain (foot 1.28.0,
Rust seatd, Rust mdevd, Laputa image); 3 done (app exit, compositor crash,
broker loss, device loss); 4 measured for the current closure.

## Locked decisions

- seatd-only libseat, `LIBSEAT_BACKEND=seatd` enforced in tinyland; no
  automatic fallback, ever. Daemon loss is a fatal error, not a reopen.
- The Laputa binary links dynamically (`-C target-feature=-crt-static`).
  A static-PIE binary with DT_NEEDED entries crashes under an explicit
  loader invocation, and the proof runs the binary that way. The harness
  `.cargo/config.toml` must not leak into the container build (it carries
  mold flags and guest-root paths); the recipe deletes it and supplies
  its own flags.
- The xkbcommon crate links without a kind, which rustc resolves
  statically; the image ships only the shared library, so the recipe
  patches the vendored crate to a dylib link.
- `panic=abort` plus `gnu-stubs` for the GCC runtime: the image has no
  libgcc provider package, and doas-rs sets the same precedent.
- The guest session runs as `laputa` via `su` + `/usr/bin/xsh`
  (`/usr/bin/xshi` is disabled in the guest). XDG_RUNTIME_DIR is
  created by root with the account's UID and GID and mode 0700 under a
  root-owned 0755 `/run/user`. Existing entries with unexpected ownership,
  type, or permissions are rejected. Seat/tty group memberships live in
  baselayout.
- The visual marker must spell SGR truecolor completely
  (`48;2;255;0;255`); a truncated sequence renders as plain text and the
  screenshot gate fails with zero magenta pixels.
- Hosted tinyland CI pins `XKB_CONFIG_ROOT` at the system path; ambient
  XKB defaults do not resolve there. Laputa builds are unaffected (the
  recipe drops that env).

## Remaining roadmap

R1–R3 landed behind the same guest proof, one slice at a time with a full
profile test after each; the compositor never changed in the R1/R2 runs.
The broker-loss slice re-pinned the compositor to the HUP-check fix and
re-qualified the exact new input in the same run.

### R1 — seatd-rs substitution — landed

`packages/seatd-rs` builds the qualified seatd-rs head
`e32d93117f24aaddfc64be8a07104a36a28c927c` (codeload sha256
`e237fc42...`; Cargo.lock sha256 `77e0f156...`; staged scope: guest and
protocol proofs green at `62da737`, docs/harness-only delta to the pin)
with the locked vendored crates, plus the libseat client library cut from
the same C 0.9.3 release the old package used (`-Dserver=disabled`, so the
daemon binary is always Rust). Same installed filetree as `seatd`
(`usr/bin/seatd`, libseat headers/library, identical xinit service), so the
profile swaps one package name and tinyland keeps linking the unchanged
seatd-only libseat client. `qemu-tinyland-foot` roots `seatd-rs` instead of
`seatd` and forbids `seatd`; `tinyland` deps follow.

Evidence: package proof (daemon reports `seatd version 0.9.3`, carries no
libseat DT_NEEDED, names no `/bin/sh`) plus the full profile test green
end to end (`make profile-tinyland-test`: coldplug, direct-open denial,
brokered session, QMP input, magenta screenshot). Closure carries
`seatd-rs`, not `seatd`. Watch points hold: `-g seat` socket stays 0770
through group mediation (`laputa` in `seat`), `SEATD_VTBOUND=0` unbound
operation is unchanged, and no automatic fallback exists anywhere.

### R2 — mdevd-rs substitution — landed

`packages/mdevd-rs` builds the staged port head
`4334f17` (codeload sha256 `33b93330…`; Cargo.lock sha256 `ef1bbbda…`;
docs-only delta to the qualified `c3f4593`, whose guest, protocol, and
combined-run proofs are green) with the locked vendored crates: `mdevd`
and `mdevd-coldplug` with the same installed filetree and the same xinit
service name/argv as the C pair (`-O 4 -f /etc/mdev.conf -C`). Only the
tinyland profile swaps (`mdevd-rs` for `mdevd`, `mdevd` forbidden); the dwl
profile and the installer keep the C daemons. The package proof checks
`-N` against live-syntax rules (move, alternation, new ptmx rule) and
rejects a syntax error with exit 2.

Watch points re-proven in the guest: coldplug completes before
deterministic discovery (`/dev/dri/card0`, both input nodes), `-O 4`
rebroadcast still feeds the session, `-C` spawns the helper, and the R5
node rules apply under the port (`/dev/ptmx mode=438`, `/dev/console
mode=400` in the proof log). Evidence: full profile test green with a
closure carrying `mdevd-rs` and no C `mdevd`.

### R3 — lifecycle depth — landed

Compositor crash and broker loss are guest-proven: the proof SIGKILLs
tinyland mid-session, observes the session exit, restarts only the
session, then SIGKILLs seatd, observes the session exit with no
direct-open fallback, and restarts broker plus session behind the same
readiness/input markers. Evidence: `CRASH`/`BROKER_LOSS` exit lines plus
the standard READY/OK/magenta gate in one green run, with uptime ticks
bounding each recovery to ~1s.

Broker loss needed an upstream fix first: `libseat_dispatch(seat, 0)`
reports a dead daemon as an empty successful read, so the session ran on
silently. tinyland `e40d653` polls the session fd for hangup before
dispatching; the recipe re-pinned to it and the guest phase re-qualified
the exact new input.

Open: none in the static VM. Supported device loss is guest-proven: after
crash recovery the proof resolves the virtio keyboard's PCI address by name
and removes it through sysfs, and the session survives on the remaining AT
keyboard — `TINYLAND_INPUT_LOST remaining=1`, node gone, no stuck
modifiers, post-loss input still flows to the OK marker. The guest drives
removal itself so the outcome never depends on host scheduling; the
observed sequence matches a host unplug (REMOVE uevent, ENODEV to open
handles, node gone). ENODEV on one of N keyboards drops just that device
(modifiers reset), exit only at zero.

### R4 — VT-bound profile — landed

A VT-bound variant of the profile with real VT switching: VT-bound seatd
session, switch handling, disable/resume with reestablished input and no
stuck modifiers or reused revoked descriptors. Tinyland implements the
resume path but it has never been guest-proven. The kernel prerequisites
have landed on x86_64 (`CONFIG_VT`, `CONFIG_VT_CONSOLE`,
`CONFIG_FRAMEBUFFER_CONSOLE`, `CONFIG_HOTPLUG_PCI_PCIE` with its port
driver, all olddefconfig-derived and dwl-regression-green); aarch64 keeps
the previous config until its qualification unblocks. Guest qualification
is green on the same serial plus QMP-key-driven machine (no new QEMU
devices needed).

Two findings from qualification. First, the switch must be compositor-
initiated via `libseat_switch_session`: a grabbed AT keyboard never
delivers the combo to the console layer, so host key injection alone
cannot move the VT. Second, revoke lands in the kernel before its disable
notification, so the compositor drains a bounded dispatch on ENODEV and
lets a pending suspend win over an unplug verdict; it also closes dropped
inputs on the broker, since the daemon hands back dups of its cached fds
and a leaked entry poisons the next open. Evidence: one green run shows
the tty1→tty2→tty1 transitions, `TINYLAND_SEAT_DISABLED`/`ENABLED` around
the switch, and the magenta marker after resume.

### R5 — device node ownership follow-up — landed

mdevd coldplug is the last writer on the static nodes (its catch-all sets
root:root 0660), so `baselayout` `mdev.conf` now owns both modes outright:
`(ptmx) root:tty 666` and `(console) root:tty 620`. The guest proof no
longer chmods either node; it logs the effective modes and asserts the
broker socket stays 0770. Evidence: `LAPUTA_TINYLAND_NODE` lines show
`/dev/ptmx mode=438`, `/dev/console mode=400`, `/run/seatd.sock mode=504`
with the proof green, and the dwl proof still passes against the shared
config. Answered first: devtmpfs/`rc.boot` create `/dev/ptmx` first at
boot, then mdevd coldplug rewrites it — the observed pre-rule 0660 was the
mdevd catch-all, which is why the fix had to be a rule.

Socket ownership is root:seat (daemon runs as root, `-g seat`); the mode
assert plus successful group mediation through `laputa`'s seat membership
pins the R1 watch point.

### R6 — hotplug, only if needed

The profile proves fixed-device coldplug plus deterministic discovery. If a
lifecycle ever requires live hotplug, add a processed-event consumer over
the libudev-zero rebroadcast. Do not add libinput or libudev-zero to
tinyland for the static contract. Not needed by R1–R5: no qualified path
adds or removes devices at runtime, so no action.

### R7 — publication

Releases and Laputa integration remain the owner's call. Neither
seatd-rs nor mdevd-rs has release tags (their staged contracts pin
`e32d931` and `4334f17` with measured hashes), so there are no published
tarballs to migrate the recipe sources to yet. When tags exist, migrate
off the pinned git SHAs and re-qualify the exact new inputs.

Consolidation (owner-approved): move tinyland, seatd-rs, and mdevd-rs
in-tree as top-level source trees (one-time history-preserving merge per
repo; recipes address them as `repository/` sources, which the PM resolves
against the checkout root and content-hashes into the plan), then point
the recipes at the local trees and archive the old repos read-only. Carry everything: docs, harnesses,
tests, benches. Drop `.github/` — Laputa's package proofs and guest
qualifications replace hosted CI as the gate; do not recreate per-repo
workflows inside the monorepo. Keep `xsh` a separate checkout (the
substrate boundary runs one way), and leave `doas-rs` out until it becomes
a real package input.

### R8 — dwl default swap and removal (owner decision)

Swap the canonical profile only after R1–R3 plus the exact-chain evidence
hold without qualification gaps. Waiting for a broad desktop feature set
would defeat the purpose; the kiosk profile is the intended endpoint.

## Explicit non-goals

doas-rs is unrelated to display devices and does not block any item above.
Pointer support, multiwindow behavior, and GPU composition are separate
projects with their own qualification.
