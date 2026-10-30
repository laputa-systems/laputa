# QEMU Proof

`qemu-dwl-foot` is the canonical reference profile. `qemu-tinyland-foot`
is the opt-in kiosk profile: unprivileged tinyland through seatd-mediated
devices and Laputa foot, without dwl, wlroots, libinput, libdrm, Mesa, or
wayland-libs-server in the runtime closure. Each profile's acceptance test
boots the immutable image built by `laputa build`; it does not assemble a
filesystem from a handwritten package list.

## Host targets

The profile CLI runs natively on the host, builds the image in Docker for the
host's architecture, and boots it with hardware acceleration: HVF on macOS
aarch64, KVM on Linux aarch64 and x86_64. `qemu_target` in `system/qemu.xsh`
owns the machine, console, block device, and display per host; the profile
holds only system intent. On x86_64 `-vga none` makes the virtio GPU the only
display, so QMP's screendump captures the compositor and not q35's VGA text
console.

## Host requirements

- `qemu-system-<arch>` for the host's architecture on `PATH`, or named by
  `QEMU_SYSTEM_AARCH64` or `QEMU_SYSTEM_X86_64`. On macOS, Homebrew's `qemu`.
- KVM on Linux: `/dev/kvm` must be usable by your user.
- QEMU's virtio GPU PCI device; on Alpine install
  `qemu-hw-display-virtio-gpu` and `qemu-hw-display-virtio-gpu-pci`.
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

The `qemu-tinyland-foot` profile has the same verbs under
`make profile-tinyland-build`, `profile-tinyland-test`,
`profile-tinyland-boot`, `profile-tinyland-plan`, and
`profile-tinyland-clean`.

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

The guest coldplugs devices, starts seatd, the profile compositor, and foot,
and emits its `*_PROOF_OK` marker only after foot launches, then keeps the
compositor running until the host stops the guest. A passing test requires
that marker and a screenshot containing the terminal's magenta visual marker.
It rejects `Kernel panic`, `not syncing`, and the profile's `*_PROOF_FAILED`
marker; inspect `console.log` and `qemu.log` first when it fails.

The tinyland profile additionally requires the direct-open denial marker:
unprivileged opens of the DRM and evdev nodes must fail while the brokered
session succeeds. Its proof also covers lifecycle behind pre-readiness
markers: compositor crash reclaim and broker-loss fail-closed restart.

The `qemu-tinyland-vt-foot` variant proves the same stack behind a
VT-bound seatd session: the guest switches away and back across virtual
terminals, and the compositor must suspend (devices revoked) and resume
(reopened input, no stuck modifiers) before the host injects input. VT
switches are one-shot QMP key operations like input injection and are
never retried.

QMP retries use a closed operation type that admits readiness and screenshot
requests. Input injection is a separate one-shot operation and cannot be passed
to the retry path. If the helper sends an input event but loses its response,
it reports an indeterminate outcome and exits with status 75. XSH maps that
status to `QmpFailure.OutcomeIndeterminate` and does not retry the operation.
The helper remains Python pending LAP-35's reusable XSH client.

The terminal reader prints and flushes its visual marker, records the injected
input, then waits for another terminal read. The host captures and checks the
marker before stopping QEMU. A nonempty screenshot without the marker fails.
The supervisor regression proves this ordering against a fake peer. Actual
visual VM qualification remains open until the graphical artifact builds.

Readiness and screenshot retry up to 20 times with 250 ms between attempts.
The supervisor owns the 180 s proof timeout, TERM/KILL escalation, final
console-marker scan, and screenshot check. The supervisor reports an early
QEMU exit as an error. The profile overlay digest is bound into the generated
image so a guest proof cannot validate a different root generation.

Run `$XSHT test tests/system/qemu.xsh` for typed dispatch and supervisor
coverage. Run `python3 tests/system/qmp_proof.py` for the disconnect-after-send
case against a local QMP peer.

Browsers, real hardware, IPv6, and Wi-Fi are outside this proof.

The test-only clock qualification invokes `boot/qmp-proof.py stop SOCKET` and
`cont SOCKET` once each, with a five-second process budget in its host harness.
These modes reuse the existing protocol client and never retry. They control
the disposable VM only.

## QMP replacement baseline

Before LAP-35, QMP has the following boundary. LAP-39's final comparison remains
open until a replacement passes the same behavior checks.

| Responsibility | Current owner and cost |
|---|---|
| Host entry points | `system/qemu.xsh` dispatches readiness, input, VT-switch, and screenshot operations. Guest clock qualification also uses one-shot `stop` and `cont` helper modes. |
| Process boundary | One Python helper process per operation attempt. Readiness and screenshot can each start up to 20 processes. Input and VT-switch start once each. |
| Wire conversion | XSH passes argv to Python. Python serializes QMP JSON and decodes replies over a new Unix connection for each invocation. |
| Protocol ownership | Python reads the greeting and negotiates capabilities on each connection. It skips events while waiting for a command response. |
| Input mutation | Seven key presses plus Ctrl-D produce 18 input requests. A VT switch is three keys down and up. A lost response stops the operation with exit 75. |
| Error ownership | Python distinguishes rejection from an unknown mutation outcome. XSH owns typed status mapping, read-only retries, and QEMU cleanup. |
| Source and dependencies | The helper is 160 lines and requires host Python. The complete supervisor module is 405 lines, including launch and visual checks outside QMP. QEMU remains external. |
| Missing protocol guarantees | No request IDs, bounded frame size, or socket deadline. The supervisor's process timeout does not establish those guarantees. |
| Verification | Fourteen native supervisor tests (including the visual-marker regression and the VT-switch ordering test) and three local peer tests covering input disconnect and one-shot pause dispatch/errors. A replacement also needs fragmented frames, interleaved events, errors, EOF, and actual VM proofs. |

This baseline measures responsibilities and crossings, not a runtime speedup.
Removing Python earns credit only when the implementation and dependency are
actually removed without losing the one-shot mutation and cleanup contracts.

The supplied fixed XSH source already provides bounded fd reads, short-write
counts, polling, close, and process-local monotonic time. The remaining portable
socket gap is connection setup: AF_UNIX socket creation and connect are exposed
under `linux.*`, whose implementation rejects other platforms. `unix.open_fd`
opens files and does not connect to socket paths. LAP-35 therefore still needs
a portable, bounded Unix-stream connection boundary to preserve the macOS path.

## Maintained VM activation

The x86_64 `qemu-maintained` overlay starts one `xinit scan boot` under PID 1
and routes scanner diagnostics to ttyS0. `laputa.xsh -- build qemu-maintained`
builds the immutable generation image. The image contains no operator keys or
machine host key.

The launcher requires a separate, owner-private `{output}/state.ext4` containing
`etc`, `home`, `var`, and a `format` file with `laputa-maintained-state-1` followed
by a newline. Initialize those directories from the selected image, apply the
first-boot document with `system.first_boot.apply`, and format the state tree as
ext4. Keep the state image at mode 0600. The guest mounts this disk on virtio vdb
and binds the three directories before starting services. Configuration belongs
to this shared state. There is no automatic configuration merge or state migration.
A candidate requiring incompatible state must not be admitted for automatic rollback.

Before binding persistent `/var`, the boot hook captures the immutable generation
receipt in `/run/laputa-running-generation.json`. The guest health reporter writes
`/run/laputa-health.json` after Dropbear reaches running state and emits the same
JSON with `LAPUTA_ACTIVATION_HEALTH` on serial. The report contains the selected
id, pending-boot sequence, full PM `generation_sha256`, profile, and named xinit
service states. The full generation identity includes the profile overlay.
`root_digest` in an activation receipt denotes this publisher identity, never
the disk-file SHA-256.

`activation_publish_image` accepts already verified local inputs. It copies kernel
and disk into a private staging directory, writes `receipt.json`, fsyncs the
files and directory, and publishes the bundle without replacing an existing id.
The receipt format is `laputa-activation-image-1`. It binds the activation receipt
to separate kernel and disk hashes. Selection checks both hashes and the receipt
before counting an attempt. Missing metadata or changed image bytes fail closed.
These local checks do not authenticate a downloaded release or defend against an
administrator who can rewrite both image and receipt.

Activation records use `laputa-activation-3` and include `boot_serial`. Older
records are rejected, with no silent migration. Every pending boot
increments the sequence, including retries after restaging. The QEMU command line
carries the selected id and sequence. `activation_confirm_guest_health` checks the
report against the pending receipt, sequence, and a host-owned critical-service
policy while holding the activation lock. A missing, duplicated, unhealthy, or
stale required-service observation prevents confirmation. The caller must obtain
a fresh report through its trusted guest channel. The lower-level
`activation_confirm_health` remains an explicitly trusted manual transition.

Activation mutations and `activation_collect_images` share the OS-backed
`activation.flock` writer lock. Process death releases the lock automatically;
its file stays in place and must not be unlinked while writers can run.
Install and stage verify a published image under that lock before recording it.
Collection retains current, fallback, and pending images. A candidate collected
before staging is rejected without changing the record and must be republished.
Publication and verification belong to `system/activation.xsh`; the launcher
consumes verified images for boot selection.

Run `python3 tests/integration/activation_recovery.py` on Linux with `strace`
installed to kill writers or inject ENOSPC at each record fsync boundary during
staging, selection, and confirmation, then verify recovery and concurrent staging.
These checks establish process-death recovery and reported sync-error handling;
they do not simulate power loss or filesystem write reordering.

`guest/qemu-maintained-proof.xsh` runs only with
`LAPUTA_MAINTAINED_PROOF_FLAG=1`. It saves seven identity/account hashes on the
state disk, requests reboot through PID 1, and compares the hashes on the next
boot. The generation disk retains `snapshot=on`; only the state disk persists.
Adding `LAPUTA_FIREWALL_FAILURE_PROOF=1` selects the negative firewall fixture.

On 2026-10-29, Linux x86_64/KVM proofs established:

- two verified generation boots with identity unchanged on the separate state disk;
- staging a distinct B while A runs, A requesting reboot, B reporting its running
  generation and critical services, and the host committing B while B remains alive;
- two actual unbootable-B kernel panics followed by launcher selection of healthy A;
- rejection of changed kernel/disk bytes, mismatched receipts, incomplete publication,
  missing state, and public state permissions before consuming a boot attempt;
- fresh guests with missing or rejected nftables rules keeping Dropbear down.

All owned QEMU PIDs were reaped. The initial writable-generation reboot proof was
superseded by the separate-state proof. The firewall fixtures and initial fallback
proof predate the new bundle metadata contract. Remote XSH transport, DHCP lease
lifecycle, first-boot crash atomicity, configuration migrations, and security-policy
admission across rollback remain separate obligations.

The maintained state mount is an early boot hook under
`/usr/lib/init/rc.early.d`, after `/proc`, `/sys`, `/dev`, and `/run` are mounted
but before `fstab`, clock, hostname, and sysctl consumers read persistent `/etc`.
A KVM regression fixture with persistent `vm.swappiness=17` failed before this
ordering change and passed afterward. `LAPUTA_BOOT_POLICY_PROOF=1` enables that
assertion in the guest proof.

Dropbear readiness requires a listening TCP socket owned by the supervised
Dropbear child of the scanner at the configured address and port. Merely spawning
the process does not satisfy readiness. The native Linux regression command is
`python3 tests/integration/dropbear_readiness.py PATH_TO_PACKAGED_DROPBEAR`.
It verifies a real owned listener and a conflicting foreign listener, then stops
and reaps every child it starts.
