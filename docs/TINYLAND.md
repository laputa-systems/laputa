# Tinyland kiosk profile

`qemu-tinyland-foot` uses an unbound seat. `qemu-tinyland-vt-foot` uses a
VT-bound seat. Both run unprivileged tinyland and Laputa foot through Rust
seat and device brokers. `qemu-tinyland-ghostty` is the canonical profile;
the foot profiles and `qemu-dwl-foot` remain rollbacks.

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

Qualified implementation: Laputa `c522589ad62ff4caa61e146da81daf535c371699`,
with XSH seed `4fb485e1cd9f45dced714b4bb365306a3abfab67`, Linux 7.2.9,
and x86_64 KVM. The subsequent documentation closeout changes no package input.

The initial guest failed because the symlinked XSH su applet could not resolve
`lib.auth`. XSH now resolves entry-relative imports beside the symlink target.
Further guest failures exposed unreadable `/dev/tty`, non-executable session
entry points, and a removed-keyboard assumption. Those installed paths now pass.
An intermittent compositor exit was traced to treating a nonblocking DRM
`EAGAIN` as fatal. Its regression now waits for an actual flip event without
changing the presentation deadline.

`make test-components-integration` passed with explicit native XKB inputs:

- Host component tests and lints, including 42 Tinyland tests and the failed-build
  harness controls; 342 PM, 102 system, one integration, 42 xinit, 39 kernel
  planner, and six kernel-header tests passed.
- All eight retained privileged mdevd adversarial cases passed in disposable
  Docker containers. These are source tests, separate from distribution proofs.
- All three PM-built KVM profiles passed. Both Tinyland guests exercised the
  exact installed doas and XSH su paths, permitted and denied identities and
  commands, private configuration rejection, live TIOCSTI policy, runtime
  directory attacks, and the same-device access-granted negative control.
- The unbound guest passed compositor crash, keyboard removal, broker loss,
  application exit, and scanner shutdown with old owned processes reaped and
  one replacement broker of each kind. The VT guest passed switch and resume.
  Both retained real keyboard input, foot rendering, and screenshot checks.
- A no-op profile rebuild preserved the generation, all four component payload
  timestamps and sizes, and their identities, without Cargo compilation.

The standalone Seatd release idle gate passed with both readiness checks exiting
0. This does not establish performance parity for the dynamically linked image.

PM receipt artifact identities and verified compressed-payload SHA-256 values:

| Package | Artifact key | Payload SHA-256 |
|---|---|---|
| doas-rs | `22a98d1fdc93b5fd19695efbab78702fcd796ef1d2a457a20ed58a950700e163` | `e9c92952f4c123e7fb8a7ee9cbb60fed575fc3ec357c241e88a4f28729ace76e` |
| mdevd-rs | `ac5c51b0e3b0f3ef785f697237bb25dc127963cce4c675ea56dc9b0212896c9d` | `6a7cee1b2ca6984801fca889268cdf6be5c35459fac9a3906d4dd24335e1bf2f` |
| seatd-rs | `d072dd12c0fc1e75435a2aa4054a0774bd8c80d2f08acb1272fec7039ce73f88` | `c0e748bd5399009f00fff4936a04adfbe58910b1fa53d2e4ddfd629775e5b8fa` |
| tinyland | `fd64294d5956a57ef1d2972600f0b1dc0fe1eef9ad0aca30c2a4db1c39d8f766` | `8f7532ec24b08f5c74f578135d2ca7a9605acf436d22e8bfff49d6bb49fcb393` |
| xsh | `4311d91e537017c6ad5c5a0a0b2fa31042a81d3427a643280a9e17439f97f774` | `87d96e36abd02d24230daa2b3a339d06b54fa2850dccbd023e6391aaf0f59421` |
| foot-minimal | `e5a16e7fc2871d41c6326b635c91622eec50f722d37d565b2d7a80ad7a8a5947` | `634989f2eb042637fe4bec10a7dec3ba06a9c8157a3adc6d66eea693ea3aea77` |
| linux | `a0b7590b8e61cbe432316e9d0412267c8b907ddea7580394b80a68369f9f5963` | `07e51239cc644114dae975c26a629a680f018c4dde86fddaec32af02c8c7fe8e` |

The existing PM store retains each `artifact.json` under
`.out/artifacts/x86_64/v2/sha256/<artifact-key>/`. Generation plans bind the full
closures and overlays, beyond the selected packages above:

| Profile | Generation SHA-256 |
|---|---|
| qemu-tinyland-ghostty | `0b168a30fa4c9b1ab3b7d064864a6526368465101271f029bf46935bdc8e10b2` |
| qemu-dwl-foot | `e40c101617c6462741f3a0111de59e64ffbdfa7bc493f82e092d7c1c8cfc0b27` |
| qemu-tinyland-foot | `88f29d08b6cc17c82b5022dbaced1b5c8f7b324ae4e34ce4d0c4d5cf6056696c` |
| qemu-tinyland-vt-foot | `5df73e3be34354813b30e168e1d9647c4e96b329ac9da8dba3c6e4b529a7e8a9` |

Linux aarch64 and macOS host execution remain unverified. The owner selected
the x86_64 Tinyland Ghostty profile as canonical; the foot and dwl profiles
remain rollbacks. The Ghostty package is published separately.

The root gate also exposed and repaired seed acceptance being persisted after
activation. A separate interruption during seed copying can still leave an
incomplete trust generation. That recovery gap and the development delegation
policy prevent treating these graphical results as production qualification.

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
remain outside this integration campaign. The owner promoted the Ghostty
profile separately in the Ghostty campaign; qualification itself changes no
profile.
