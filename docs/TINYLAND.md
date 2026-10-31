# Tinyland kiosk profile

`qemu-tinyland-ghostty` is the canonical profile: unprivileged tinyland and
Ghostty through Rust seat and device brokers, with the compositor scanning
out on a 2D GPU and Ghostty rendering on virgl. It requires a host GPU render
node (`docs/QEMU.md`).

## Source and artifact contract

The authoritative implementations live in `tinyland/`, `mdevd-rs/`,
`seatd-rs/`, and `doas-rs/`. Their recipes consume `repository/` inputs.
Source edits change PM build identities without an intermediate release.
Cargo `target` output and ignored harness scratch are excluded from inputs.
XSH remains a separate substrate checkout.

`pm/rust.xsh` owns standard-library staging shared by the four recipes.
Each recipe retains its explicit linker, dependency, and patch policy.
No Rust dependencies or toolchain pins changed in this hardening pass.

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
Mdev policy gives the special `/dev/tty` node mode 0666 so an ordinary user
can open its controlling terminal; numbered VT permissions remain separate.

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

The profile stages the installed-doas qualification helper. It uses the
XSH su applet and the packaged `/usr/bin/doas`, including terminal-attached
and detached execution. An explicit loader invocation cannot establish a
setuid transition.

One xinit scanner owns mdevd, seatd, and the session.
Mdevd signals readiness before the coldplug oneshot runs. Seatd starts after
successful coldplug and signals readiness separately. Launchers require actual
readiness rather than accepting xinit's timeout promotion. Session exit,
compositor loss, and broker loss restart the session under that scanner.
The proof counts broker instances and binds reader readiness to each session.

## Verification entry points

`make test-components` runs the retained host component checks. Native
libxkbcommon and XKB rules are prerequisites. See [testing](TESTING.md) for
those inputs and the explicit integration target.

`make profile-test` composes PM artifacts and boots the disposable
qemu-tinyland-ghostty guest. Preserve the real keyboard-to-Ghostty input,
changed pixels, confirmed presentation, and screenshot checks alongside
crash, broker-loss, device-removal, and scanner-shutdown cases.

Keep package and generation receipts as the artifact identity source.
A source check, cross-build, or unavailable KVM run is not guest qualification.
Linux aarch64 and unsupported VT infrastructure require separate evidence.

## Current qualification

`make profile-test` builds the canonical image from the published
`ghostty-custom-1.4.1-2` and passes on Linux x86_64/KVM. The guest exercises
the installed doas and XSH su paths, permitted and denied identities, live
TIOCSTI policy, runtime-directory attacks, the same-device access-granted
negative control, compositor crash, single keyboard removal, broker loss,
application exit, scanner shutdown, Ghostty on a 4.3 core context, and
modifier input. Numbers, the release tag, and the generation hash are in
[the Ghostty campaign](CAMPAIGN-TINYLAND-GHOSTTY.md).

Linux aarch64 and macOS host execution remain unverified. The root gate also
exposed and repaired seed acceptance being persisted after activation. A
separate interruption during seed copying can still leave an incomplete trust
generation. That recovery gap and the development delegation policy prevent
treating these graphical results as production qualification.

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

Pointer support, multiwindow operation, and real hardware remain outside this
integration campaign.
