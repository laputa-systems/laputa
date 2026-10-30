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
to the retry path. If an input event loses its response, the supervisor reports an indeterminate
outcome and does not retry. Both supported host platforms use `system/qmp.xsh`
over `unix.connect_stream`; QMP control requires no Python process.

The terminal reader prints and flushes its visual marker, records the injected
input, then waits for another terminal read. The host captures and checks the
marker before stopping QEMU. A nonempty screenshot without the marker fails.
The supervisor regression proves this ordering against a fake peer. At
`e105c09`, `make profile-test XSH_ROOT=../xsh XSH_BIN_DIR=.out/host/x86_64`
passes on Linux x86_64/KVM with the canonical graphical closure and native XSH
QMP. The host captures the terminal marker before stopping the guest.

The portable-stream replacement also passes this Linux x86_64/KVM proof with
the qualified static SDK built from XSH `ee486105c`. Its size budgets and
matching-profile memory gate pass. macOS and aarch64 runtime proofs remain open.

Readiness and screenshot retry up to 20 times with 250 ms between attempts.
The supervisor owns the 180 s proof timeout, TERM/KILL escalation, final
console-marker scan, and screenshot check. QMP attempts and retry delays share
the proof deadline. The supervisor reports an early
QEMU exit as an error. The profile overlay digest is bound into the generated
image so a guest proof cannot validate a different root generation.

Run `$XSHT test tests/system/qemu.xsh` for typed dispatch and supervisor
coverage. Run `XSH=/path/to/xsh python3 tests/system/qmp_client.py` for the local
protocol cases. Python is a test-peer dependency, not a VM control dependency.

Browsers, real hardware, IPv6, and Wi-Fi are outside this proof.

The test-only clock qualification sends `stop` and `cont` once each with a
five-second budget. The commands control the disposable VM and are never retried.

## QMP replacement baseline

At `55b9f68`, before the native Linux client, QMP has the following boundary.
The table records the retired boundary for the source and responsibility comparison.

| Responsibility | Current owner and cost |
|---|---|
| Host entry points | `system/qemu.xsh` dispatches readiness, input, VT-switch, and screenshot operations. Guest clock qualification also uses one-shot `stop` and `cont` helper modes. |
| Process boundary | One Python helper process per operation attempt. Readiness and screenshot can each start up to 20 processes. Input and VT-switch start once each. |
| Wire conversion | XSH passes argv to Python. Python serializes QMP JSON and decodes replies over a new Unix connection for each invocation. |
| Protocol ownership | Python reads the greeting and negotiates capabilities on each connection. It skips events while waiting for a command response. |
| Input mutation | Seven key presses plus Ctrl-D produce 18 input requests. A VT switch is three keys down and up. A lost response stops the operation with exit 75. |
| Error ownership | Python distinguishes rejection from an unknown mutation outcome. XSH owns typed status mapping, read-only retries, and QEMU cleanup. |
| Source and dependencies | The helper is 184 lines and requires host Python. The supervisor module is 461 lines, including launch and visual checks outside QMP. QEMU remains external. |
| Missing protocol guarantees | No request IDs or frame-size bound. The per-socket timeout does not bound the complete operation and retry sequence. |
| Verification | Fourteen native supervisor tests (including the visual-marker regression and the VT-switch ordering test) and three local peer tests covering input disconnect and one-shot pause dispatch/errors. A replacement also needs fragmented frames, interleaved events, errors, EOF, and actual VM proofs. |

This baseline measures responsibilities and crossings, not a runtime speedup.
Removing Python earns credit only when the implementation and dependency are
actually removed without losing the one-shot mutation and cleanup contracts.

The native client uses XSH's bounded fd reads, short-write counts, polling,
close and process-local monotonic time. `unix.connect_stream(path, timeout)`
returns a caller-owned nonblocking, close-on-exec descriptor with portable Unix
address handling. `qmp_run_until` carries the supervisor's absolute deadline
through connection setup and every exchange. Callers use `qmp_run` for a single
operation with a duration budget.

The native supervisor covers readiness, input, VT switches, screenshots and
pause/resume. Frames are limited to 1 MiB; replies match request IDs and events
are skipped while awaiting replies. Fifteen peer cases and fourteen supervisor
cases cover these contracts. `QemuConfig` contains only the QEMU executable and
target; `qemu_config(target)` does not discover a Python helper.

| Boundary | Native implementation |
|---|---|
| Host entry points | The same readiness, input, VT, screenshot, pause and resume operations. |
| QMP subprocesses | None; requests stay in the host XSH process. |
| Argument conversion | Native JSON encoding and decoding replace the XSH-to-Python argv crossing. Screenshot filenames use structured QMP arguments. |
| Lifetime | One bounded connection per operation, with ordered input steps, response IDs and an absolute deadline shared with the supervisor. |
| Laputa source | The client and supervisor total 615 lines, versus the previous 645 lines of helper and supervisor. The helper and its runtime dependency are removed. |
| Shared substrate | XSH adds the reusable Unix stream connection operation using its existing rustix dependency. That Rust host boundary is additional first-party source. |
| Verification | Local protocol peers and supervisor fixtures remain Python test tooling. Linux x86_64/KVM provides the graphical proof; macOS and aarch64 runtime qualification remain separate. |

This removes the subprocess, duplicated transport selection and second protocol
implementation. Source counts do not establish a speedup. XSH's distribution
size gate applies to the added shared operation.

## Maintained VM activation

The x86_64 `qemu-maintained` overlay starts one `xinit scan boot` under PID 1
and routes scanner diagnostics to ttyS0. `laputa.xsh -- build qemu-maintained`
builds the immutable generation image. The image contains no operator keys or
machine host key.

The boot target supervises two foreground services from the XSH core. The
`logger` service runs `syslogd --state /run --socket /dev/log` with notify
readiness and always-restart; its captured output lands in
`/var/log/logger/current` on the state disk under xinit's bounded
copy-truncate rotation. The `dhcp-eth0` service runs the supervised DHCPv4
client with its lease directory in `/var/lib/dhcpc` on the state disk, run
state in `/run/dhcpc`, and the resolver composed into `/etc`; the operator
static file at `/etc/dhcpc/resolv.static` is read-only input, so dhcpc is the
single owner of `resolv.conf`. Neither service blocks boot, rescue, or login:
dependents use `after` at most, and Dropbear's `need` set stays
`firewall`, `dropbear-keygen`, and `net`. The loopback-only `net` oneshot is
unchanged and the interfaces file carries no `eth0` or `inet6` stanza, so no
second client contends for the lease. IPv6 stays unsupported on this profile:
no DHCPv6 or router-advertisement handling is configured or tested. Service
declarations and the resolver split are pinned by
`tests/system/maintained_services.xsh`; guest lifecycle requalification
(renew, rebind, NAK, expiry, link loss, pause/resume, restart with a saved
lease) remains a KVM-gated step and is not claimed here.

The launcher requires a separate, owner-private `{output}/state.ext4` containing
`etc`, `home`, `var`, and a `format` file with `laputa-maintained-state-1` followed
by a newline. Initialize those directories from the selected image, apply the
first-boot document with `system.first_boot.apply`, and format the state tree as
ext4. Keep the state image at mode 0600. The guest mounts this disk on virtio vdb
and binds the three directories before starting services. Configuration belongs
to this shared state. There is no automatic configuration merge or state migration.
A candidate requiring incompatible state must not be admitted for automatic rollback.
Host admission currently supports only `laputa-maintained-state-1`. It rejects
different state declarations rather than migrating the shared disk. Publishers
must attest that admitted code preserves this contract, including application
data schemas; a matching string alone cannot prove semantic compatibility.

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
The receipt format is `laputa-activation-image-2`. It binds the activation receipt
to separate kernel and disk hashes and the shared-state format. Selection checks both hashes and the receipt
before counting an attempt. Missing metadata or changed image bytes fail closed.
These local checks do not authenticate a downloaded release or defend against an
administrator who can rewrite both image and receipt.

Activation records use `laputa-activation-4` and include `boot_serial`. Older
records are rejected, with no silent migration. Before upgrading an existing
installation, stop all activation writers, including v3 writers, and retain an
independent rescue route. Re-publish verified images with v2 receipts and install
a fresh v4 host record with explicit admission pins; do not relabel old JSON or
delete the guest state disk. Keep the old host record separately until the
replacement is verified. Before first installation, stop every pre-v3 writer
and use one writer version per state directory.
The earlier writer uses `activation.lock`; it cannot coordinate with
`activation.flock`. Format rejection protects an existing record but does not
serialize first installation by mixed writer versions. Every pending boot
increments the sequence, including retries after restaging. The QEMU command line
carries the selected id and sequence. `activation_confirm_guest_health` checks the
report against the pending receipt, sequence, and a host-owned critical-service
policy while holding the activation lock. A missing, duplicated, unhealthy, or
stale required-service observation prevents confirmation. The caller must obtain
a fresh report through its trusted guest channel. The lower-level
`activation_confirm_health` remains an explicitly trusted manual transition.
Both confirmation APIs require an active pending boot and recheck host admission.
They also verify the retained fallback remains admitted and intact. If policy
revokes recovery, confirmation fails even when the candidate reports healthy.
This guard does not depend on successfully saving a failed-boot marker when
storage is unavailable.
After exhausting attempts, an inadmissible fallback closes that boot's health
window and returns an error requiring independent recovery.

`AdmissionPolicy` lives in the host activation record, outside immutable guest
images and the guest state disk. It has a strictly increasing revision and an
explicit list of `ImageAdmission` pins. Each pin binds the complete generation
receipt, kernel hash, disk hash, and state format. `activation_install` requires
an initial policy. `activation_update_policy` replaces the pins under the writer
lock and refuses a repeated or lower revision. An empty pin set blocks every
normal boot. Updates apply to subsequent admission, selection, and confirmation;
they do not terminate an already running guest.

`activation_publish_image` returns an `ImageAdmission`, but publication does not
authorize it. A trusted host operator must add the pin explicitly. For production
inputs, verify the authenticated release through its existing delivery boundary
before authorizing the exact artifacts. Do not copy authorization from untrusted
image metadata. Host pins are an operator authorization mechanism, not a substitute
for signed repository metadata or TLS distrust enforcement.

Staging retains the current healthy generation as fallback. Confirmation and
fallback preserve the latest host policy. Revoked content remains inadmissible
even if its files are retained; changing guest generations never restores old
pins. If current selection or fallback is inadmissible, use independent rescue
to inspect state and authorize verified replacement inputs. There is no automatic
unsigned exception, policy rollback, or shared-state migration.

For trusted local build inputs, initial installation is explicit:

```xsh
let admitted = activation.activation_publish_image(
  state, receipt, kernel, disk, activation.ACTIVATION_STATE_FORMAT,
)?
activation.activation_install(state, receipt, {revision: 1, images: [admitted]})
```

Adding a candidate requires publishing it, authorizing its returned pin through
`activation_update_policy` at a higher revision, and then calling
`activation_stage`. A stale policy-update request fails instead of overwriting
a newer revision. After losing a reply, read status and reconcile its revision.
An older caller must upgrade before writing: a v3 record cannot express the v4
admission policy. Policy revisions and shared-state compatibility need explicit
review during replacement; recreating the record must not restore revoked pins
or authorize an incompatible retained image.
An operator can stage an already retained, still-admitted generation through
the same API to request rollback. This preserves the current policy revision
and does not authorize replaying stale remote repository metadata.

Activation mutations and `activation_collect_images` share the OS-backed
`activation.flock` writer lock. Process death releases the lock automatically;
its file stays in place and must not be unlinked while writers can run.
Install and stage verify a published image under that lock before recording it.
Collection retains current, fallback, and pending images. A candidate collected
before staging is rejected without changing the record and must be republished.
Publication and verification belong to `system/activation.xsh`; the launcher
consumes verified images for boot selection.

Run `python3 tests/integration/activation_recovery.py` on Linux with `strace`,
`unshare`, `mount`, and `umount` installed and unprivileged user namespaces enabled.
The test kills writers or injects ENOSPC at each record fsync boundary during
staging, selection, confirmation, and policy updates. It also exercises concurrent staging and
collection, closes reply pipes before acknowledgments, and fills an isolated
1 MiB tmpfs until writes return ENOSPC. Full-filesystem failures preserve the
record; freeing space permits retry. Reply loss is reconciled by reading status.
These checks establish process-death recovery, local reply-loss handling, and
full-filesystem behavior. They do not simulate power loss, filesystem write
reordering, or an SSH transport disconnect.

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
lifecycle, first-boot crash atomicity, automatic configuration migrations, signed
production image delivery, and TLS consumer distrust remain separate obligations.

On 2026-10-30, a Linux x86_64/KVM run exercised v4 host admission with v2 image
receipts. B panicked twice. Before fallback, host policy revision 2 revoked B
while retaining A. The launcher selected A, its guest identity proof passed,
and revision 2 remained in the host record. Revision 3 then revoked every image;
normal selection was refused. The independent, network-free rescue guest still
returned clean/repaired/unrecoverable statuses 0/1/8 and verified the repaired
payload hash. All four QEMU PIDs were reaped. This qualifies host artifact pins
across fallback, not production signing-key distribution or TLS consumer distrust.

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
