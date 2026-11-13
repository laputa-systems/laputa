# QEMU Proof

`qemu-tinyland-ghostty` is the canonical profile: unprivileged tinyland
through seatd-mediated devices and Ghostty Custom rendering on virgl. Each
profile's acceptance test boots the immutable image built by `laputa build`;
it does not assemble a filesystem from a handwritten package list.

## Host targets

The profile CLI runs natively on the host, builds the image in Docker for the
host's architecture, and boots it with hardware acceleration: HVF on macOS
aarch64, KVM on Linux aarch64 and x86_64. `qemu_target` in `system/qemu.xsh`
owns the machine, console, block device, and display per host; the profile
holds only system intent. On x86_64 `-vga none` makes the virtio GPU the only
display, so QMP's screendump captures the compositor and not q35's VGA text
console.

A virgl profile carries two GPU devices: a 2D `virtio-gpu-pci` first, so it
becomes card0 and the compositor scans out through a host-readable surface,
then `virtio-gpu-gl-pci` as the render device. QEMU's `screendump` returns
`no surface` for a GL scanout because those frames stay GL textures, so this
split keeps both the guest's OpenGL 4.3 context and the host pixel proof.

## Host requirements

- `qemu-system-<arch>` for the host's architecture on `PATH`, or named by
  `QEMU_SYSTEM_AARCH64` or `QEMU_SYSTEM_X86_64`. On macOS, Homebrew's `qemu`.
- KVM on Linux: `/dev/kvm` must be usable by your user.
- QEMU's virtio GPU PCI device; on Alpine install
  `qemu-hw-display-virtio-gpu` and `qemu-hw-display-virtio-gpu-pci`.
- Profiles with `qemu_gpu: Virgl` also need virgl and a host GPU render
  node: on Alpine `qemu-hw-display-virtio-gpu-gl`,
  `qemu-hw-display-virtio-gpu-pci-gl`, `qemu-ui-egl-headless`,
  `qemu-ui-opengl`, and `virglrenderer`. `test` renders through
  `-display egl-headless`; `boot` uses `gtk,gl=on` on Linux, which also needs
  `qemu-ui-gtk`.
- `make seed` done for the host arch. The profile build needs no mirror.

## Commands and outputs

```bash
make profile-build    # laputa.xsh -- build qemu-tinyland-ghostty
make profile-test     # laputa.xsh -- test qemu-tinyland-ghostty
make profile-boot     # laputa.xsh -- boot qemu-tinyland-ghostty
make profile-plan     # laputa.xsh -- plan qemu-tinyland-ghostty
make profile-clean    # laputa.xsh -- clean qemu-tinyland-ghostty
```

`laputa.xsh` also takes `--jobs N` (`$XSH_HOST laputa.xsh -- build
qemu-tinyland-ghostty --jobs 4`).

- `plan` writes `target/laputa/qemu-tinyland-ghostty/build-plan.json`. Two runs from
  clean profile output produce byte-identical plans.
- `build` resolves or builds exact package artifacts in the shared store
  `.out/artifacts/<arch>`, composes an immutable generation, and atomically
  publishes one complete system bundle under `builds/<system-key>/`. `current`
  switches to that bundle only after its plan, generation manifest, kernel,
  root filesystem, and disk image are all verified. A warm run reuses matching
  artifacts and keeps the plan digest, generation digest, and image hash.
- `test` and `boot` first build or refresh `current`. `test` is
  deterministic: it starts QEMU without a display, uses QMP to inject the
  profile's line exactly once, waits for the bounded guest proof, and saves a
  screenshot. Success prints exactly
  `laputa test qemu-tinyland-ghostty: ok`.
- `boot` opens QEMU's interactive display with the profile's session. It is a
  diagnostic path, not the acceptance test.
- `clean` removes only `target/laputa/qemu-tinyland-ghostty`, never the
  artifact store. `make clean` removes all derived state.

Each bundle `builds/<system-key>/` contains `build-plan.json`,
`generation.json`, `disk.img`, `rootfs.ext4`, and `vmlinuz`. `current` is an
atomic symlink to one complete bundle. `console.log`, `qemu.log`, and
`screenshot.ppm` are proof outputs at the profile root. Image construction
stages generation and rootfs data on the container's Linux filesystem; only a
complete verified bundle is copied atomically to the host output mount.

## Proof contract

The guest coldplugs devices, starts seatd, the profile compositor, and its
terminal, and emits its `*_PROOF_OK` marker only after the terminal launches,
then keeps the compositor running until the host stops the guest. A passing test requires
that marker and a screenshot containing the terminal's magenta visual marker.
It rejects `Kernel panic`, `not syncing`, and the profile's `*_PROOF_FAILED`
marker; inspect `console.log` and `qemu.log` first when it fails.

The tinyland profile additionally requires the direct-open denial marker:
unprivileged opens of the DRM and evdev nodes must fail while the brokered
session succeeds. Its proof also covers lifecycle behind pre-readiness
markers: compositor crash reclaim and broker-loss fail-closed restart.

QMP retries use a closed operation type that admits readiness and screenshot
requests. Input injection is a separate one-shot operation and cannot be passed
to the retry path. The profile's `proof.input_mode` selects the keys:
`ProofPlain` types a lowercase line, and `ProofModifiers` drives Caps Lock,
Shift, and a bare modifier press and expects `LAPUTA!` from the reader. If an input event loses its response, the supervisor reports an indeterminate
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

The boot target supervises three foreground XSH services. The
`logger` service runs `syslogd --state /run --socket /dev/log` with notify
readiness and always-restart; its captured output lands in
`/var/log/logger/current` on the state disk under xinit's bounded
copy-truncate rotation. The `dhcp-eth0` service runs the supervised DHCPv4
client with its lease directory in `/var/lib/dhcpc` on the state disk, run
state in `/run/dhcpc`, and the resolver composed into `/etc`; the operator
static file at `/etc/dhcpc/resolv.static` is read-only input, so dhcpc is the
single owner of `resolv.conf`. The DHCP service uses notify readiness: the
fixed XSH client writes its readiness byte to the supervisor pipe once the
interface is resolved and its loop is armed, before it acquires a lease. The
syslog receiver writes its readiness byte directly and keeps notify. The
third service is `laputa-timers`, the supervised scheduler described under
[persistent timers](#persistent-timers). None of them blocks boot, rescue,
or login: dependents use `after` at most, and the `oxish` service's `need` set stays
`firewall`, `oxish-hostkey`, and `net`. The loopback-only `net` oneshot is
unchanged and the interfaces file carries no `eth0` or `inet6` stanza, so no
second client contends for the lease. IPv6 stays unsupported on this profile:
no DHCPv6 or router-advertisement handling is configured or tested. Service
declarations and the resolver split are pinned by
`tests/system/maintained_services.xsh`. `tests/integration/maintained_guest.py`
drives the KVM proofs from a provisioned state disk (see below): a clean boot
proves identity survival across reboot with logger and dhcp supervised, a
bound lease, a managed resolver, and a boot-marker log count of two; a
fallback drill (two power cuts on a pending generation, then boot) proves the
logs name the failed generation with its service history and no secrets,
with a marker count of three and the activation record resting on the
fallback with pending cleared and the failed generation named.
`maintained_guest.py --firewall` boots fresh
state disks whose `/etc/nftables.conf` is absent or not valid nft syntax (`nfcrt` rejects it):
the firewall oneshot must fail without becoming `running`, `oxish` must have no
process and no ready listener, and the guest must not reach the identity proof. The guest then powers itself
off through PID 1 (`SIGUSR2`) and QEMU must exit without a host kill, which
needs an ACPI PM1 power-off path in the x86_64 kernel.

The DHCP client itself is requalified with the existing
`xinit/tests/fixtures/dhcp_vm_host.xsh` fixture against the fixed XSH
services (XSH `b6b5e5a1d`, which writes readiness to the supervisor pipe):
a 5 s host pause leaves the guest bound (monotonic/boot clocks
exclude the pause, only the RTC steps), a ±day wall step keeps the lease
bound with one renewal, and a carrier flap plus a device remove/rescan
rebinds on the new interface index. Renewal, rebind, NAK, and expiry paths
are covered by the XSH namespace suites that qualified the client.

The launcher requires a separate, owner-private `{output}/state.ext4` containing
`etc`, `home`, `var`, and a `format` file with `laputa-maintained-state-1` followed
by a newline. Initialize those directories from the selected image (including the
image's static `/etc` files, the maintained inittab, the packaged firewall
ruleset (`/etc/nftables.conf` from the `crabtables` package), the ca-certificates trust store that `ntpd-rs` needs for NTS, and the loopback-only interfaces file), create the service-owned
`/var/lib/dhcpc` (mode 0700) and `/var/log` staging directories the image never
contains, apply the first-boot document with `system.first_boot.apply`, and
format the state tree with `system/maintained_state_image.xsh`. Pass the staged
root, output path, size in bytes, native ext4 formatter path, and XSH binary path:

```sh
XSH_MODULE_PATH="$PWD" xsh system/maintained_state_image.xsh -- \
  STATE_ROOT state.ext4 268435456 packages/laputa-fs/files/mkfs.ext4.xsh /path/to/xsh
```

The entry validates the applied document, account IDs, the operator home, and the
root-owned `etc/oxish/accounts`, then assigns the operator's UID and GID to the
home inode. Other image entries, including `etc/oxish`, use root ownership. Staging itself does not change
host ownership. The output image is private and atomically published.
First boot assigns new operators `/usr/bin/xsh-login`, which accepts remote `-c`
commands as XSH source. The standard seed does not provide an interactive login
shell. Existing operator accounts keep their configured shell. The DHCP client
creates only its own leaf directory, so provisioning owns the parents. The guest
mounts the state image on virtio vdb and binds the three directories before
starting services. Configuration belongs to this shared state. There is no
automatic configuration merge or state migration.
A candidate requiring incompatible state must not be admitted for automatic rollback.
Host admission currently supports only `laputa-maintained-state-1`. It rejects
different state declarations rather than migrating the shared disk. Publishers
must attest that admitted code preserves this contract, including application
data schemas; a matching string alone cannot prove semantic compatibility.

Before binding persistent `/var`, the boot hook captures the immutable generation
receipt in `/run/laputa-running-generation.json`. The guest health reporter writes
`/run/laputa-health.json` after `oxish` reaches running state and emits the same
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

Activation records use `laputa-activation-5` and include `boot_serial` plus an
optional `failure` record. A fallback writes `failure` with the abandoned
generation receipt and the attempts it consumed, so the host record names what
did not boot after `pending` is cleared. The next stage or confirmation clears
`failure`; a fallback boot of the retained current generation leaves it in
place. Older records, including v4, are rejected with an error naming the found
and required formats, with no silent migration. Before upgrading an existing
installation, stop all activation writers, including v4 writers, and retain an
independent rescue route. Re-publish verified images with v2 receipts and install
a fresh v5 host record with explicit admission pins; do not relabel old JSON or
delete the guest state disk. Installing that fresh record discards the previous
selection and failure history, so read status first and keep the old host record
separately until the replacement is verified. Before first installation, stop
every pre-v3 writer and use one writer version per state directory.
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
An older caller must upgrade before writing: a v4 record cannot express the v5
failure history. Policy revisions and shared-state compatibility need explicit
review during replacement; recreating the record must not restore revoked pins,
authorize an incompatible retained image, or claim a failure history it did not
observe.
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
full-filesystem behavior. They do not simulate power loss or filesystem write
reordering. `LAPUTA_XSH` selects the host XSH when it is not
`.out/host/x86_64/xsh`; the G2 drill passes the same binary there.

Run `python3 tests/integration/activation_ssh.py XSH PORT KEY PIN` against a
disposable maintained guest with a `probe` account, a maintained generation
receipt, and `LAPUTA_ACTIVATION_SSH_FIXTURE=1` on its kernel command line.
Forward the guest SSH port to localhost and supply the client key and pinned
host key. Place a guest-compatible `strace` in
`/home/probe/ssh-proof/tools/strace` and its shared libraries in the same
directory. For the tested Alpine musl binary the libraries are `libdw.so.1`,
`libelf.so.1`, `libz.so.1`, `libfts.so.0`, `libzstd.so.1`, `liblzma.so.5`,
and `libbz2.so.1`. The guest must allow the probe account to trace its own
child. Use a fresh activation directory; preparation removes stale trace,
commit and release markers and rejects existing activation state.

The fixture delays the first fsync after writing `activation.next`. A second
SSH connection observes the unfinished fsync before the test kills the first
client. After the writer continues, reconnect verifies current, fallback and
pending records and image hashes, rejects duplicate staging, and selects B
through the launcher. The run with deliberately stale markers also passed.
The fixture invokes production host APIs over SSH, not an installed activation
CLI. This covers one disconnect during staging and does not establish physical
power-loss behavior. [Testing](TESTING.md#run-the-vm-storage-publication-fault-cases)
records separate VM filesystem publication cases.

### G2 integrated lifecycle

`tests/integration/g2_lifecycle.py` runs roadmap G2 steps 1-6 on one installed
x86_64/KVM VM:

```sh
python3 tests/integration/g2_lifecycle.py --xsh PATH/TO/xsh \
  --bundle target/laputa/qemu-maintained/current \
  [--oxish-keygen PATH/TO/oxish-keygen] [--keep]
```

Without `--oxish-keygen` the test extracts `usr/bin/oxish-keygen` from the
`oxish` package artifact under `LAPUTA_ARTIFACT_STORE` (default
`.out/artifacts/x86_64/v2/sha256`). The host needs KVM, `strace`, `unshare`,
`mount`, `ssh-keygen`, and the bundle's `vmlinuz`, `disk.img`, and
`generation.json`. The artifact store must hold `baselayout`, `musl`, `xsh`,
`xinit`, and `e2fsprogs` for the chained rescue drill; when it does not, the run
prints that rescue is unverified and continues. Step 6 additionally needs the
store's `rustic` and `gnu-stubs` artifacts, `mkfs.ext4`, and network access on
the first run to fetch restic into a tool cache; missing artifacts or
`mkfs.ext4` stop the run at its prerequisite check with exit 77 instead of
reporting a pass, and the restore stage itself raises rather than degrading to
a skip. `--keep` retains consoles, the state image, generation bundles, the
restore media and backup repository, and the host activation record. Fetched
restic is cached under `.cache/restore-tools`.

The test provisions a fresh state disk with a unique OxiSH host key (made by
`oxish-keygen`, mode `0600`, pinned by its `SHA256:` fingerprint) and a
locked-password `probe` account whose first-boot record adds it to the reserved
`xinit-admin` group and whose `authorized-key` becomes its line in
`/etc/oxish/accounts`, and checks that the immutable generation disk contains
neither the operator's authorized public key nor the operator's private key
body. It installs generation A from the bundle under policy revision 1, runs the
existing `rescue_guest.py` for an independently composed rescue root
(clean/repaired/unrecoverable disks), and boots A through the launcher. Over the
verified native SSH path it checks the pinned
host key, running receipt and health report, critical service states, the
root:`xinit-admin` 0770 control inbox, the bound
lease and dhcpc-owned resolver, the observed clock-service state, and redacted
diagnostics. Restarting `logger` and `dhcp-eth0` as the non-root `probe`
operator goes through the scanner's verified control inbox and rechecks new
pids, accepted-request log lines carrying the operator uid, readiness, and a
rebound lease; a QMP `set_link` down/up breaks and restores SSH and requires a
bound lease afterwards.

The test then runs the existing `activation_recovery.py` and
`activation_ssh.py` drills against the same run, stages generation B (the real
kernel with a zeroed disk) under policy revision 2, flushes the guest
filesystems as `probe`, quits QEMU, and boots B twice. B never reaches
userspace; the host bounds each attempt and
selects retained A after the cap with `LAPUTA_FAILED_GENERATION=b` and the host
record's `failure` naming B's receipt and two consumed attempts. The next stage
clears that `failure` record; the persistent host key and a staged home sentinel
survive, and the boot marker history names the A boots and failed B. The
repaired C is staged from the bundle under policy revision 3, booted, checked
for a matching running receipt and live `oxish`, `logger`, and `dhcp-eth0`,
and only then confirmed through `activation_confirm_guest_health`. A further C
reboot shows the committed record and the retained four-entry history.

The last stage closes step 6 by driving the R7 restore drill's functions from
`restore_drill.py` against that same committed C. It reads the pre-restore
identity files, host key, staged home sentinel, running receipt, inspection
record, and boot-marker history over verified SSH as the non-root `probe`
operator, then flushes the guest filesystems and quits QEMU. `/etc/shadow` is
never read as a UID 0 administrator; the fixture's `/etc/shadow` body is
captured when the state disk is provisioned and matched as bytes inside the
committed state image before the drill and inside the restored blank disk
afterwards, the same raw-image inspection the harness already uses for the
sentinel. The skeleton image used for the restore is required not to carry that
body, so the containment check cannot pass on an untouched base. With the
immutable image bundle and a template argv that carries no generation token, it
snapshots C's `/etc`, `/home`, and `/var` into a fresh rustic repository on the
backup disk after removing the first repository key, restores that repository
onto a newly built blank state disk, and asserts the blank disk changed and
carries the sentinel. The blank disk replaces the state disk, and the restored
VM boots committed C with boot serial 3. The same verified SSH path then
re-reads the operator-readable identity files, host key, sentinel, receipt,
inspection, service states, and boot markers, requiring them to match the
pre-restore capture; only one new marker entry may appear. The drill therefore
runs its own backup/restore/verify code rather than a G2-side reimplementation.

On 2026-11-12 this passed on Linux x86_64/KVM against the `qemu-maintained`
generation `769b73813b3b…` built from this tree with the verified
`xinit-admin` control inbox. It establishes G2 steps 1-6 under the no-root
model for that bundle only: no UID 0 administrator is provisioned, the
maintained `probe` account restarts supervised daemons through the xinit
`xinit-admin` control plane and shutdown is an operator filesystem flush
followed by a QMP quit. It does not establish natural T1/T2 lease renewal,
physical power loss, Linux aarch64, Asterinas, a macOS client, signed release
authenticity, or clean PID 1 poweroff, which remains unverified because no root
operator can signal PID 1 in this model. Step 6 restores the committed state
onto a blank disk through the R7 repository. Staging digests pin bytes and the
PM `generation_sha256` is publisher identity, not a signature.

### Persistent diagnostics

`packages/laputa-diagnostics` installs `usr/lib/laputa/diagnostics.xsh` and a
boot oneshot `usr/lib/xinit/services/diagnostics.xsh`. The oneshot runs
`/usr/bin/xsh /usr/lib/laputa/diagnostics.xsh --phase boot` with
`XSH_MODULE_PATH=/usr/lib/xsh/core` and `after` on `logger`; it never gates
boot, rescue, or login. The profile must select the package; its package-root
list is profile-owned.

One collection writes `/var/log/diagnostics/` on the maintained state disk:

- `events.log` is JSON Lines with boot id, `CLOCK_BOOTTIME` nanoseconds,
  wall-clock nanoseconds, generation id, boot serial, failed generation, kind,
  and detail. A stable key makes repeated collection idempotent. The newest
  512 lines and 64 KiB are kept.
- `boot-history.json` reduces the health reporter's `/var/log/boot-markers.log`
  to the newest 20 activation entries with generation id, boot serial, failed
  generation, profile, root digest, and named service states.
- `lease.json` keeps only `state`, `address`, and `prefix`; client
  identifiers, server ids, and the raw lease file never enter the store.
- `support.tar.gz` is the bounded redacted bundle described below.

A collection reads the existing syslog path (`/var/log/logger/current`),
`/dev/kmsg`, `/run/laputa-running-generation.json`,
`/run/laputa-health.json`, `/run/xinit/*.json`, and
`/run/dhcpc/eth0.status`. It does not start another logger or replace xinit's
capture. Timestamps pair `boot_id` with `boottime_ns`, so a pre-sync wall clock
does not make boot and service order ambiguous; `wall_ns` is retained only as a
display and calendar hint. The failed generation comes from the launcher's
`LAPUTA_FAILED_GENERATION` token, the host activation record's `failure` entry,
and the persisted boot markers.

The support bundle runs the existing XSH `system-report --json --section`
collectors for `identity`, `kernel`, `storage`, `network`, and `processes`.
Sections are redacted by `system-report` by default; `--sensitive` is never
passed. Each section is capped at 32 KiB, the staging tree at 240 KiB, and the
published `support.tar.gz` at 256 KiB. Optional sections are dropped in
`processes`, `network`, `storage`, `kernel`, `identity` order when the cap would
be exceeded and are named in the manifest. The whole store is bounded at
384 KiB. `diagnostics --canary PATH` reads a test secret from `PATH` only to
prove it never reaches the store or bundle; a normal collection passes no
canary.

A failed write leaves the previous file in place: replacement is one atomic
rename and each file is fsynced with its parent. A full state disk reports
`LAPUTA_DIAGNOSTICS_DEGRADED ... preserved=1` and leaves the prior bundle and
events intact; freeing space lets the next collection publish again. This is
bounded retention, not lossless logging. xinit copies `current` to `current.1`
and truncates in place, so a write between copy and truncate can be lost; a
failed rotation leaves `current` in place and keeps the supervisor alive. The
syslog receiver drops datagrams from a full socket queue, by sender/global
rate, by oversize, by descriptor passing, and at a blocked sink, and counts
each. Kernel records the ring has already overwritten are reported as an
overrun rather than reconstructed. No remote syslog, fleet collector, or
journald-compatible store is implied.

`tests/system/diagnostics.xsh` covers redaction, retention, history, lease
projection, bundle bounds, and write-failure preservation offline.
`tests/integration/diagnostics_reboot.py` boots a maintained generation,
kills QEMU twice while generation B is pending, and proves on the fallback
boot that the persistent store names failed generation B with its service
history, stays inside the declared bounds while the state disk is filled to
ENOSPC, recovers after space is freed, and publishes no canary secret. It uses
`LAPUTA_XSH` and `LAPUTA_QEMU_OUTPUTS` to select the host tools and built image.

### Persistent timers

`packages/laputa-timers` installs `/usr/lib/laputa/timers.xsh` (the scheduler
and its pure decision core), `/usr/lib/laputa/timers-run.xsh` (the entry point
that owns the termination hook), the xinit service
`/usr/lib/xinit/services/laputa-timers.xsh`, the generation job directory
`/etc/laputa/timers/jobs.d`, and a link to the pinned core
`lib/monotonic.xsh`. The service is one foreground process on target `boot`
with notify readiness and always-restart. Readiness means the definitions,
state, and cancellation markers are loaded and the live snapshot is published,
not that a job has run. Nothing takes `need` on it. The profile overlay ships
two real calendar job definitions: `daily-sync`, which runs `/usr/bin/sync`
daily at 03:17 UTC, and `backup`, which runs
`/usr/lib/laputa/backup.xsh run` daily at 03:47 UTC.

`backup` reads `/etc/laputa/backup.json` from the same generation-owned `/etc`.
The shipped configuration keeps the newest three snapshots of `/etc /home /var`
in `/mnt/backup/repo`, stops `logger` and `dhcp-eth0` through
`/usr/lib/laputa/backup-quiesce.xsh` before the snapshot, checks the repository
with `rustic check` after it, prunes with `rustic forget --keep-last 3 --prune`,
and writes `laputa-backup-receipt.json` beside the repository. The runner
exits nonzero on any failed step, so the timer records the outcome and applies
its bounded retries. See [backup](BACKUP.md) for the contract and key policy.
The manual restore drill in `tests/integration/restore_drill.py` remains the
primary restore proof.

Job definitions are generation input under `/etc`; the maintained state disk
carries the administered copy. Durable run state is
`/var/lib/laputa-timers/state.json` on the state disk, and the live snapshot
and lock are under `/run/laputa-timers`. Interval deadlines use the process
monotonic clock, calendar deadlines use UTC wall time, overlap is `skip` or
`queue` per job, and missed occurrences collapse into at most one run. The
full contract, including the clock-step and VM-pause behavior, is in
[timers](TIMERS.md).

`tests/integration/timers_guest.py` provisions a disposable state disk with a
three-second interval job, a calendar definition, and a failing job with two
bounded retries, then boots the rebuilt `qemu-maintained` generation under KVM.
It asserts: the shipped `daily-sync` next occurrence, interval runs, at most
three attempts per failing occurrence, cancellation holding for two intervals
and resuming, a 20-second QMP pause with no catch-up burst, a cold boot of the
same state disk with a coalesced catch-up and a persisted calendar anchor, an
`xinit restart` that reloads state and keeps running, and the same status
through the existing fixed remote program's `run` operation. On 2026-11-11 the
run passed with exit 0: the QMP pause froze every guest clock (`resume=steady`;
7.29 s of both wall and boottime elapsed across the post-pause window), so the
guest observed no elapsed time, no occurrence was due, and the interval job ran
normally with no burst. The cold boot's 13 missed intervals produced one
catch-up (`coalesced=13`, three runs in the window) and the calendar anchor was
unchanged. A guest whose clock instead advances across a pause is classified
as a gap or wall step and coalesces in the same way; neither case can produce a
burst.

`tests/integration/backup_schedule.py` boots the same rebuilt generation twice
with an ext4 backup disk attached. A ten-second timer job runs the shipped
backup runner against a fixture password and repository. A fixture writer
appends to `/var/lib/backup-proof/writer.log`; the configured quiesce hook
stops it and `logger`/`dhcp-eth0`, the snapshot is taken, `rustic check` runs,
keep-last pruning leaves exactly three snapshots, and the receipt names the new
snapshot. A second job runs the same runner with a missing key, and the test
observes its nonzero outcome, bounds it to the two configured attempts, and
shows that cancelling it stops the failure counter. The second boot mounts the
backup disk and a blank disk, reads the receipt, restores that exact snapshot,
and verifies the identity hashes and the quiesced writer line count from the
restored state. It reuses the restore drill's provisioning, launch, and serial
helpers. The manual restore drill remains the primary proof.

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
- fresh guests with missing or rejected firewall rules keeping the SSH server down
  (proved before SSHB-7 with the previous SSH server; the `oxish` service has not rerun it, see LAP-57).

All owned QEMU PIDs were reaped. The initial writable-generation reboot proof was
superseded by the separate-state proof. The firewall fixtures and initial fallback
proof predate the new bundle metadata contract. Remote XSH transport, DHCP lease
lifecycle, first-boot crash atomicity, automatic configuration migrations, signed
production image delivery, and TLS consumer distrust remain separate obligations.

On 2026-10-30, a Linux x86_64/KVM run re-proved the clean boot with the
DHCP service back on notify readiness (XSH `6d992dd`, containing the `b6b5e5a1d`
readiness-pipe repair). The guest reported `dhcp-eth0` running with a bound
lease and a managed resolver, and the boot-marker log counted two across the
PID-1 reboot. The fallback drill re-proved with the same image: two power cuts
on pending B, logs naming failed B with `dhcp-eth0` running in its service
history, and the record resting on A with pending cleared. All owned QEMU PIDs were reaped.

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

`oxish` readiness requires a listening TCP socket owned by the supervised
`oxish-server` child of the scanner at the configured address and port. Merely
spawning the process does not satisfy readiness. The native Linux regression command is
`python3 tests/integration/oxish_readiness.py PATH_TO_OXISH_BIN_DIR`, a directory
holding `oxish-server`, `oxish-session` and `oxish-keygen` (an unpacked release
archive's `bin/`); it runs as an unprivileged account with `XSH_HOST` naming the host `xsh`.
It verifies a real owned listener and a conflicting foreign listener, then stops
and reaps every child it starts.
