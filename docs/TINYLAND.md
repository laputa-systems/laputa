# Tinyland kiosk profile

`qemu-tinyland-foot` uses an unbound seat. `qemu-tinyland-vt-foot` uses a
VT-bound seat. Both run unprivileged tinyland and Laputa foot through Rust
seat and device brokers. `qemu-dwl-foot` remains the canonical reference.
Promotion requires an explicit owner decision after current qualification.

## Source and artifact contract

The authoritative implementations live in `tinyland/`, `mdevd-rs/`,
`seatd-rs/`, and `doas-rs/`. Their recipes consume `repository/` inputs.
Source edits change PM build identities without an intermediate release.
Cargo `target` output and ignored harness scratch are excluded from inputs.
XSH remains a separate substrate checkout.

Keep separate binaries and component interfaces. No shared Cargo workspace,
D-Bus, logind, PAM, polkit, or desktop stack is required.

PM package proofs validate the distribution artifacts. Guest qualification
must use those artifacts and their installed paths. Standalone static builds
are component evidence and cannot qualify the dynamically linked Laputa
`doas` or `tinyland`. The libseat backend is explicitly `seatd`; broker loss
must never select direct device access.

## Session security contract

Normal boot loads `usr/lib/sysctl.d/10-terminal.conf`, which disables
`dev.tty.legacy_tiocsti`. When doas is installed, boot requires the live value
to be zero before running user-session hooks. Doas retains its independent
terminal refusal check. Development passwordless delegation is not a
production security policy.

Privileged setup resolves the `laputa` account and creates `/run/user` as
root:root 0755, then `/run/user/<uid>` as the account's UID and GID with mode
0700. It rejects existing entries with the wrong type, ownership, or mode.
The parent directories prevent an unprivileged user replacing the selected
entry. Ownership changes do not follow symlinks.

The session records real and effective identities, supplementary groups,
and effective capabilities. Device denial probes open DRM read/write and
evdev read-only with nonblocking descriptors. Only EACCES and EPERM count
as denied access. Missing devices and unrelated errors fail qualification.
The guest deliberately grants access to the same DRM node and requires the
probe to fail before restoring the node mode. A second account attempts to
plant runtime-directory symlinks.

Both profiles stage the installed-doas qualification helper. It uses the
XSH su applet and the packaged `/usr/bin/doas`, including terminal-attached
and detached execution. An explicit loader invocation cannot establish a
setuid transition.

One xinit scanner owns mdevd, seatd, and the session in both profiles.
Mdevd signals readiness before the coldplug oneshot runs. Seatd starts after
successful coldplug and signals readiness separately. Launchers require actual
readiness rather than accepting xinit's timeout promotion. Session exit,
compositor loss, and broker loss restart the session under that scanner.
The proof counts broker instances and binds reader readiness to each session.

## Verification entry points

`make test-components` runs the retained host component checks. Native
libxkbcommon and XKB rules are prerequisites. See [testing](TESTING.md) for
those inputs and the explicit integration target.

`make profile-tinyland-test` and `make profile-tinyland-vt-test` compose PM
artifacts and boot the corresponding disposable guests. Preserve the real
keyboard-to-foot input, changed pixels, confirmed presentation, and screenshot
checks alongside crash, broker-loss, device-removal, and VT cases.

Keep package and generation receipts as the artifact identity source.
A source check, cross-build, or unavailable KVM run is not guest qualification.
Linux aarch64 and unsupported VT infrastructure require separate evidence.

## Current qualification

The hardening run starting at `962be46` reached the x86_64 guest but failed
before the graphical session: installed `/usr/bin/su` could not resolve its
relative `lib.auth` import through the applet symlink. The resulting boot
failure exited PID 1. This is an XSH loader boundary defect, not evidence
that installed doas successfully elevated.

The descriptor-repair regression fails before the doas fix and passes after
it for all seven combinations of closed standard descriptors through exec.
Repair errors now fail startup. The mdevd qualification regression requires
a failed Cargo build to stop before stale executable inspection. Source
checks and local filesystem probes do not replace the pending guest controls.

Current guest acceptance, supervisor recovery, and architecture coverage must
be re-established against the final composed generation before promotion.

## Historical graphical evidence

Before the hardening run, the profiles recorded successful mediated rendering
and keyboard input using Laputa foot 1.28.0. Earlier external source pins
included tinyland `e40d653`, seatd-rs `e32d931`, and mdevd-rs `4334f17`.
These pins describe historical runs; recipes now use the in-tree sources.

The unbound proof recorded compositor-crash recovery, broker-loss session
termination, and removal of one keyboard while input continued on another.
The VT-bound proof recorded tty1-to-tty2-to-tty1 transitions, seat disable and
resume, and the post-resume magenta marker. Device removal is covered;
adding devices dynamically remains outside the static kiosk contract.

Those runs used the old read-based denial assertion and manually managed
broker recovery. They establish historical rendering and input behavior,
not the stronger mediation and supervisor claims under review now.

Pointer support, multiwindow operation, GPU composition, and real hardware
remain outside this integration campaign. Do not publish releases or change
the canonical profile as part of qualification.
