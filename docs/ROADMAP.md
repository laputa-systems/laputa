# Roadmap

Make Laputa a small, reproducible, XSH-managed operating system that can remain
useful unattended: a VM should survive service crashes, network loss, interrupted
updates, and virtual-disk damage, with an inspectable recovery path.

After the in-tree tinyland, mdevd-rs, seatd-rs, doas-rs, and ntpd-rs integration is
qualified, the next step change is the [remotely maintainable VM](#g2-the-remotely-maintainable-vm):
install, administer, update, recover, and eventually rebuild Laputa through XSH.
SSH is the control path connecting those workflows, not an isolated additional
command. Installed-generation activation is the centerpiece that turns composed
images into an operating system that can be maintained in place.

The next investment is lifecycle correctness, not a larger command catalog.
Preserve the existing PM, typed profiles, xinit, and XSH boundaries rather than
introducing a second package manager, service manager, or deployment framework.

## Design filter: make complexity unnecessary

Laputa is the operational proving ground for XSH, not merely a collection of
Rust replacements. XSH aims to make systems work as immediate as shell scripting
while keeping behavior explicit and checkable. The useful measure is how many
independent assumptions and intermediate protocols a workflow no longer needs,
not how many commands or codecs are present.

Follow [XSH's design principles](https://github.com/laputa-systems/xsh/blob/master/docs/DESIGN.md):
a small specified language core; a minimal trustworthy systems substrate; an
expansive userspace built predominantly in XSH. Laputa supplies demanding real
consumers for those boundaries. Keep service, network, build and activation
policy in ordinary XSH; improve reusable host operations when a consumer exposes
a gap. Do not move whole commands into Rust merely to call the result native.
Established external protocol/storage engines remain appropriate where they
reduce risk rather than duplicate machinery.

Prefer architectural subtraction without removing useful capability: one owner
per invariant, typed data/OS observations instead of render-and-reparse paths,
shared libraries instead of command-specific runtime features, and fewer hidden
conversions or mandatory intermediate representations. Preserve independent
verifier and trust-boundary checks; shared definitions do not replace them.
Every substantial slice
should identify its consumer, what machinery disappears, the boundary that
changes, its failure proof and its dependency/runtime cost. This is a design
filter, not a mandate for another framework or repository-wide rewrite.

Conceptual coherence and expressive coverage do not establish implementation
economy or operational trust. Checked effects are not OS authority enforcement;
path validation is not filesystem confinement; atomic publication is not crash
durability; formal semantics are not native-adapter conformance. Require the
corresponding host/guest evidence and state its limits. Keep the language core
and substrate increasingly predictable while userspace grows above them.

Keep the four native userland components in-tree beside their recipes and
qualification. Preserve independent binaries and narrow responsibilities, but
make a source change, package rebuild, and exact-image test one development
loop. Do not restore four release-and-repin cycles or require a shared runtime
framework merely because the code now shares a repository. XSH remains the
separate substrate/toolchain boundary.

The most direct feedback loop is to build XSH inside Laputa, use it to produce a
successor system, and reduce discovered failures to ordinary regression tests.
R10 connects the existing bounded self-hosting workflow to normal activation;
R1/R2/R4/R5/R6 remain the operational consumers that give its abstractions
purpose. No new language feature is justified solely by this roadmap, and no
paused XSH campaign is resumed by it.

## Authority and scope

This document owns direction, sequencing, and acceptance milestones.
[TODO](../TODO.md) owns bounded defects and follow-ups; the topic documents linked
below own current behavior. A roadmap entry is planned work, not a claim of
implementation or permission to launch every workstream. Before implementation,
recheck the source, choose a bounded slice, and record its acceptance evidence in
the owning topic or campaign. Do not duplicate the TODO queue here.

The original planning baseline was reread after the documentation refactor at
`44572a718e3067e9d03e6646036e67f04c4ac5b2` on 2026-10-25. The systems-foundation
follow-up used Laputa `85c175515312` and XSH `9d893e0075d2`. The remote-lifecycle
planning update incorporates the in-tree direction and the subsequently recorded
DHCP/syslog, signed-snapshot, and self-hosting work. None of these documentation
reviews reran build or guest proofs. Historical defects are not automatically
current defects; the owning topic documents and exact-artifact evidence decide
what remains. G2 below remains planned, not passed.

**Supported direction:** Linux guests under QEMU on aarch64 and x86_64, plus the
pinned x86_64 Asterinas/Firecracker backend. Linux aarch64 guest qualification
is deferred pending a macOS aarch64 host via Docker; Linux x86_64 remains the
active proof target. Keep the existing graphical VM
reference working while developing the headless operational path. A feature
proved on Linux is not automatically proved on Asterinas or another architecture.
Native build hosts are test infrastructure, not a bare-metal Laputa target.
A macOS administration client is a separate host-side qualification, not evidence
that the Linux aarch64 guest or the G0 XSH candidate has been qualified there.

**Real hardware is out of scope.** Do not add physical-device enablement,
Wi-Fi or Bluetooth integration, firmware collections, physical GPU/audio/storage
qualification, laptop power management, `zzz` integration, physical suspend or
hibernation, bare-metal installers, or physical firmware/Secure Boot/TPM work.
Existing packages and hardware-related TODO entries do not authorize that work;
in particular, LAP-15 and the hardware/wireless portion of LAP-16 are deferred.
No hardware enablement is a prerequisite for this roadmap.

VM pause/resume, guest clock discontinuities, virtual NIC link changes,
virtio-device behavior, guest reboot, and disposable virtual-disk failure tests
remain in scope. Recovery and rollback may use the existing direct-kernel VM
launch paths; they do not require an EFI loader or a new bootloader campaign.
Keep D-Bus, systemd, logind/elogind, and polkit out of this direction. Runtime
identity, supervision, and remote administration use the existing XSH/Laputa
owners, not a new message bus or resident fleet-management service.

## Baseline: foundations are not missing

| Area | Existing foundation | Remaining boundary |
|---|---|---|
| Native userland | In-tree tinyland, mdevd-rs, seatd-rs, doas-rs, and ntpd-rs have package inputs and retained tests | Qualify the exact packaged chain, normal boot ownership, and regression coverage; consolidation alone is not a security or release claim. See [tinyland](TINYLAND.md). |
| Packages and images | Typed plans, immutable artifacts, runtime-only generations, atomic publication of host-side system bundles | Installed-system activation, boot success, rollback, and state ownership are not the same as composing a generation. See [PM](PM.md) and [core infrastructure](CORE-INFRASTRUCTURE.md). |
| Services | xinit scanning, readiness, restart backoff, control, and rotating stdout/stderr | Keep normal boot, tested recovery, and supervisor ownership aligned. See [init](../xinit/docs/INIT.md) and [supervision](../xinit/docs/SUPERVISION.md). |
| Remote administration | Packaged Dropbear and an installer/SSH proof | Typed XSH remote execution, persistent identity, first-boot provisioning, and one inspect/stage/recover workflow remain the next integration milestone. |
| Storage | Native image/installer filesystem tools | Installer `mkfs.ext4` is journal-less and `fsck.ext4` does not repair. See [installer](INSTALLER.md). |
| Networking and logging | XSH records supervised DHCPv4 and syslog (XSH-53/54) as implemented; Laputa has network policy, xinit, Dropbear, Tailscale, and nftables foundations | Adopt matching XSH products, roll out the services, and qualify leases/resolver ownership, time, and persistent logs in the installed image. See [XSH roadmap](https://github.com/laputa-systems/xsh/blob/master/docs/ROADMAP.md). |
| Trust | Signed repository snapshots with mandatory durable acceptance, guest HTTP/reboot proof, signed certificate releases and intermediate distrust in XSH and Tailscale | Provision production repository keys through image/first boot; upstream prebuilt uv lacks intermediate distrust. See [PM](PM.md#snapshot-authentication) and [certificate trust](CERTIFICATE-TRUST.md). |
| Self-hosting | Bounded in-guest XSH rebuild and A-to-B successor workflow | Turn the existing development proof into the normal installed build/stage/boot path without overstating bootstrap closure or production admission. See [self-hosting](SELF-HOSTING.md). |
| Verification | Package tests, installer/SSH and graphical QEMU proofs, pinned Asterinas guest tests | Existing smoke proofs do not establish long-lived operation, recovery, or platform parity. See [testing](TESTING.md), [QEMU](QEMU.md), and [Asterinas](ASTERINAS.md). |

The baseline is deliberately narrow. A package name, successful `--version`,
content-addressed artifact, or boot marker is not evidence that the corresponding
operational capability is complete. XSH-53/54 are outside the frozen XSH G0
candidate; selecting newer services requires matching binaries/core scripts and
renewed consumer qualification, not borrowing the older candidate's results.

## Priority and sequence

P0 means required before trusting a long-lived installed VM; P1 strengthens the
operational and self-hosting foundation; P2 is optional expansion. Priority is not
execution order: service ownership and focused tests unblock several P0 tracks.
Track IDs remain stable for existing TODO and topic references. Their numeric
order is not the execution sequence below.

| Track | Priority | Outcome |
|---|---|---|
| R1 | P1, foundation | One supervised boot service graph with honest readiness and failure behavior |
| R2 | P0 | Roll out persistent VM networking/syslog and qualify disciplined time |
| R3 | P0 | Repairable virtual disks and an independent rescue path |
| R4 | P0 | Operationalize authenticated repository/trust delivery with explicit freshness policy |
| R5 | P0, centerpiece | Installed-system generation activation and bounded rollback |
| R6 | P1, start alongside R1/R2 | SSH-native administration and first-boot identity for a safe long-lived VM profile |
| R7 | P1 | Persistent diagnostics and proved restore; schedule backups/maintenance afterward |
| R8 | P2, deferred expansion | A qualified opt-in Linux OCI execution profile, after the operational baseline |
| R9 | P2, consumer-driven | Selective existing tools, not additional ports or catalog growth for its own sake |
| R10 | P1, later routine workflow | Connect the existing self-hosted successor proof to normal activation |
| R11 | Deferred to the end | Typed on-demand activation and per-user agents in xinit |
| R12 | Deferred to the end | A complete Wayland desktop on one reference laptop |

The owner-selected work order is:

1. Establish typed remote XSH administration and first-boot provisioning (R6),
   using the qualified xinit graph (R1) rather than a second control plane.
2. Roll out existing DHCPv4/syslog and integrate time discipline (R2/R7). Bring
   up a reachable VM without requiring the whole update system first.
3. Join authenticated admission (R4), an independent rescue route (R3), and
   reboot-based generation activation/fallback (R5).
4. Prove persistent diagnostics and a manual restore to a blank disk (R7),
   then automate backups and maintenance. Diagnostic capture starts earlier;
   the final restore test must not be postponed behind a scheduler.
5. Make the existing in-guest XSH/cohort rebuild and successor boot a routine
   development workflow through the same activation path (R10).
6. Only after G2 and G4: typed activation (R11), then the reference-laptop
   desktop (R12).

Bounded slices can overlap. Design R4 alongside R2's clock-bootstrap policy;
R5 depends on R3's rescue path and R4's authenticated inputs. R10 can continue
independently, but must not delay a useful remote/operational baseline or be
presented as a substitute for production trust, state ownership, and fallback.
Defer broad OCI work, desktop protocol expansion, additional utility ports,
and firmware-boot work unless a concrete G2 workflow requires them. The desktop
(R11/R12) is last; it starts only after G2 and G4 pass.

Asterinas successor work runs as one serial lane alongside the G2 tracks,
because every kernel slice moves the same submodule pin and its qualification
needs quiet-host windows; the G2 tracks keep first claim on host capacity. The
qualified surface and known limits are in [Asterinas](ASTERINAS.md); the
remaining compatibility obligations are LAP-54 and LAP-55. In order:

1. **Accepted:** harness and tooling build the kernel crate's own unit tests on this host,
   make the cargo-input stamp independent of absolute paths, fetch the kernel
   without `git submodule`, and power the guest off so acceptance no longer
   trusts the completion marker alone.
2. **Accepted:** the nine Asterinas-only native failures (btop, chrt, cp,
   cpio, dd, date) pass on kernel `d4c2e3877`. Linux-paired regressions cover
   clock ticks, clock resolution, scheduler policy and execution, file-copy
   behavior, and sparse-file accounting. The other A2 clock obligations remain
   open.
3. One ICMP error slice: ICMP receive, `IP_RECVERR`, and asynchronous socket
   errors, which together serve the Asterinas-only `tracepath` and
   `traceroute` cases, EHOSTUNREACH for the unresolved-neighbor queue, and the
   matching A3/A5 debt. **Integrated and published.** The
   slice is rebased onto the LAP-54 monotonic slew at `dc4b3fffd` (44 commits
   on `434e2d626`; the rebase had no conflicts and the diff from the former
   candidate `2252e24b6` is exactly the slew change), now the fork's `main`. It
   includes the limited-broadcast DHCP fix (stop addressing those packets to a
   gateway after route selection) and the paired wildcard-bind UDP test.
   `676c828a0`, which only keeps unlisted and unrun echo and IPv6 UDP sources,
   is not part of it. Laputa's lock and gitlink name `dc4b3fffd`, and the XSH
   pin is unchanged. `qualify.sh all --backend both` on that kernel passed
   baseline, device, clock ABI, network-state (16 cases) and network (10
   cases), and failed only on the two recorded issues: the Linux-only clock
   `pause` case, and `carrier` in recovery rounds 1 and 4 of 10, whose only
   transcript difference was the `dhcpc` status-3 traceback on Asterinas.
   Quiet-host A0 accounting over the 125 A0 modules kept every original pass:
   1,326 passed, 25 failed (all already in A0's failed set), 49 skipped, no
   module interrupted or unstarted. Three interleaved resource pairs against
   the `434e2d626` kernel on a ready host put the candidate's median CPU at
   +0.08 s for boot (6.70 s against 6.62 s, inside the baseline's 0.18 s
   spread) and −0.21 s for numeric (13.92 s against 14.13 s); the kernel grew
   from 154.3 MB to 160.2 MB and the root image is unchanged.
   `qualify.sh published-inputs` passes. The `carrier` traceback was XSH's:
   a shutdown abort that reached `dhcpc` inside a net wait surfaced as a
   status-3 script failure. XSH `16a886d00` lets it cross the wait as an
   abort, and with XSH `d520fbcc5` on kernel `57aec8665`, `qualify.sh all
   --backend both` passed every cohort and all ten recovery rounds.
4. Linux page-fault cost and `MAP_POPULATE` are active performance work after
   compatibility. Any improvement needs at least five interleaved baseline
   and candidate runs, completed-work checks, and successful readiness checks.

The native slice passed `qualify.sh all --backend both`, including ten recovery
rounds, at Laputa `819896e` and kernel `d4c2e3877`. All nine exact native cases
also passed on that final kernel. Later build-job and kache plumbing preserves
the qualified kernel product.

Quiet-host accounting retained all 1,281 original A0 passes: 1,323 cases passed,
25 failed, 49 were skipped, and 13,858 of 15,255 discovered cases were
unexecuted. All 125 selected modules completed; a fail-dominant scan found no
original pass failed, and every observed failure was already in A0's failed
set. This establishes preservation of that pass set, not a full native-suite
pass. The kernel fork's `main` is published at `d4c2e3877`; the fresh
published-inputs check fetched that kernel and XSH `73f8be2a4` and matched the
lock and gitlink.

Each subsequent slice passes `qualify.sh all --backend both` and loses no A0 pass
in a quiet-host accounting run.

## G2: The remotely maintainable VM

**Status: steps 1-5 pass on Linux x86_64/KVM for one prebuilt `qemu-maintained`
generation; step 6 and the open items below remain.** `tests/integration/g2_lifecycle.py`
provisions a unique host key and key-only credentials on a fresh state disk,
installs A and boots the independent rescue root, inspects services, lease,
resolver and diagnostics over verified native SSH, restarts supervised services
as the non-root operator through xinit's `xinit-admin` control plane, and
survives a link loss, stages B while chaining the existing recovery and SSH
disconnect drills, falls back to A after two bounded B startup failures with
identity and state preserved, then health-confirms and commits a repaired C and
reads its boot history across a reboot. Open: step 6 blank-disk restore in the
same run, natural T1/T2 lease renewal, physical power loss, Linux aarch64,
Asterinas, a macOS client, and signed release authenticity.

This is the organizing product milestone, not a new manager,
new test framework, or a claim that every R1-R7 capability has shipped. The unit
of delivery is one installed VM that can be maintained through its full lifecycle.
Reuse the current image builder, PM receipts, xinit, launcher, and guest harness.

The integrated acceptance scenario is:

1. Install a fresh headless VM from trusted inputs. Provision its unique host
   identity and operator access without shared default credentials. Keep secrets
   out of public images and provide an independent local rescue path.
2. Connect from a separate administration machine through XSH's verified SSH
   path. Inspect the running generation, services, lease/resolver state, clock
   status, and redacted diagnostics. Exercise lease renewal, daemon restart,
   and temporary network loss without inventing success from process liveness.
3. Build or fetch authenticated generation B while A remains usable. Verify and
   durably stage the exact kernel/root/configuration bundle, retain A, and record
   a queryable pending operation. Disconnect during a mutation: reconnect and
   inspect its outcome, never blindly replay it.
4. Reboot into B and inject a startup failure. The existing host launcher must
   select an admissible known-good A after bounded failed attempts without
   losing mutable state. A guest that never boots cannot perform its own fallback.
5. Stage a repaired candidate, boot it, verify its running receipt and declared
   local/service health, and only then commit it. Inspect the failure and
   activation history across reboots; Internet reachability alone is not health.
6. Restore the selected mutable state onto a blank virtual disk using backup
   plus trusted artifacts, without relying on the original VM. Boot and verify
   the restored system and its explicit identity/trust policy.

Keep configuration, secrets, application data, machine identity, and persistent
trust/revocation floors outside ordinary binary-generation rollback. Migrations
that prevent fallback must be declared before activation. Restoring the same
machine and cloning a new one have different host-key/identity requirements.

The first integrated result may be Linux x86_64. Qualify the administration host,
guest architecture, and backend independently; record macOS-client, Linux
aarch64, and Asterinas gaps explicitly. Passing this scenario establishes only
its stated scope, not arbitrary power-loss durability, all hardware, or a fully
self-hosted world. Detailed state machines remain with the existing topic owners.

## R1: Make xinit the service lifecycle owner

Use one long-lived scanner for the selected boot graph, launched and supervised
by PID 1. Keep early mounts and host-independent setup in boot hooks; move
persistent daemons out of bespoke foreground/background boot scripts. Keep the
inittab engine and service scanner's distinct responsibilities documented rather
than merging them solely for code reuse.

Audit `packages/baselayout/files/rootfs/etc/inittab`, the installer's generated
inittab, profile boot hooks, and installed service modules together. Preserve
completed ownership fixes and make the normal startup path the failure-test
path. Prevent duplicate instances and conflicting scanner ownership when paths
converge. Scripted recovery alone is not proof that installed supervision owns
and performs the same recovery.

Preserve strict service normalization and graph validation already covered by
xinit's tests. Recheck readiness separately from process liveness: a named
facility without a provider must not masquerade as a satisfied critical
dependency. Keep local network configuration distinct from Internet reachability;
do not block rescue/login forever waiting for external services. Longruns must
remain foreground processes. Do not add blanket dependency restart cascades.

Give service configuration one authoritative typed model, with shape validation,
semantic checks and execution preconditions kept distinct. Reuse existing
redacted inspection and read-only planning. Executable service modules remain
trusted code, not inert data. A codec migration must not create a second service
schema, and SSH inspection must call the same local service owner.

**Acceptance:** a real VM boots the selected graph once; killing a daemon
exercises backoff and recovery; killing/restarting the scanner has a defined
cleanup/recovery path without duplicate children; malformed config and failed
readiness produce explicit status. Reboot stops owned services before filesystem
shutdown. Existing xinit proofs and the graphical reference remain valid.

**Status: lifecycle contract proven and shipped inittabs converged.**
`tests/integration/xinit_lifecycle.py` boots an x86_64/KVM guest with this
checkout's xinit as PID 1, the production `rc.boot` and `rc.shutdown`, and one
`xinit scan` entry. It proves one graph start, a delayed restart without a
dependency cascade, a SIGTERM scanner restart with one worker per unit, explicit
status for a malformed module and a readiness timeout, and a pre-shutdown hook
that sees no owned workers while the root is still writable. The proof found
`rc.shutdown` running a command named `hook` instead of each hook. The baselayout
and installer inittabs each start one `xinit scan boot`, which starts mdevd,
dropbear and networking from their boot-target modules; `mdev.supervise` is
gone, and the guest proof reads the scanner line from baselayout. Open: SIGKILL
of the scanner is unqualified, the installer QEMU smoke image was not rebuilt
to exercise the CI scanner, and the graphical reference was not rerun.

## R2: Persistent VM networking and time

### Network lifecycle

Roll out the existing XSH-53/54 foreground services, rather than starting another
DHCP or logging implementation. XSH's
[roadmap](https://github.com/laputa-systems/xsh/blob/master/docs/ROADMAP.md)
records supervised DHCPv4 and local syslog as implemented; the
[integration RFC](https://github.com/laputa-systems/xsh/blob/master/docs/rfc/XSH-53-supervised-dhcp-and-syslog.md)
records their consumer contract and rollout steps. Laputa owns package/profile
selection and xinit service configuration. Keep protocol/policy in ordinary XSH
and only reusable missing OS mechanisms in the substrate.

Select a matching XSH binary/core-script set and requalify the installed
ifup/ifdown/client path. Demonstrate renewal, rebinding, expiry, NAK handling,
restart with saved leases, link loss, and virtual NIC reappearance. Remove
expired owned addresses/routes and reconcile state after VM pause/resume. Start
with one supported virtual Ethernet path. Add explicit IPv6 policy and tests for
SLAAC/router advertisements and resolver information before claiming dual-stack
support; add DHCPv6 only where the selected profile requires it. Wi-Fi remains
excluded and IPv6 is not an entry fee for the first IPv4 remote-management slice.

Give resolver configuration one owner, atomic updates, and per-interface state.
Define how DHCP, static settings, and Tailscale coexist, including the supported
split-DNS boundary; do not let independent writers race on `resolv.conf`.
Keep name resolution separate from optional DNS caching/recursive service work.
Audit hook execution for the intended XSH/no-ambient-shell contract.

Use the network path as a shared-library consumer: observe actual state, compute
a typed plan, apply with preconditions, then re-observe. Preserve foreign resources,
including Tailscale/operator state; detect lost notifications and stale snapshots.
Partial application requires reconciliation, not a promise of generic rollback.
Recheck LAP-32/XSH-38 against the newer implementation and retire obsolete
blockers only with the corresponding installed-system evidence.

Do not install a parallel network manager to paper over a failure. Reduce a
rollout defect to a regression in the owning XSH or Laputa layer. DHCP/syslog
must remain separately supervised foreground processes, not loops inside PID 1.

**Acceptance:** use a controlled local DHCP/DNS server with short leases in VM
fixtures. Exercise renew/rebind, NAK/expiry, changed DNS/routes, daemon restart,
link loss, and pause/resume without duplicate or stale configuration. Confirm
that SSH administration recovers through the declared network behavior. Boot and
local rescue still work offline. Qualify IPv4 and IPv6 separately and report
unsupported modes explicitly.

**Status: IPv4 lifecycle proven on Linux x86_64/KVM; IPv6 and SSH recovery
open.** `tests/integration/dhcp_lifecycle.py` boots the built `qemu-maintained`
image against a scripted DHCPv4/DNS server with short leases and passes initial
bind, renewal with changed DNS and routes, rebind, NAK, a replacement lease,
expiry, daemon restart with INIT-REBOOT from the saved lease, link loss, NIC
reappearance after a PCI remove and rescan, pause and resume, a steady-state
sample with no duplicate or stale configuration, and an offline boot that stays
locally administrable. The run found two XSH client defects, fixed upstream: a
negative wait after a slow re-acquisition and a re-created NIC left down. SSH
recovery through the declared network and IPv6 policy are not yet qualified.

### Time discipline and bootstrap

The in-tree `ntpd-rs` has a Graviola/rustcrypto musl package and xinit service.
It runs as reserved UID/GID 123 with only `CAP_SYS_TIME`; initialization readiness
does not imply synchronization. The `qemu-maintained` profile enables it with an authenticated NTS-only configuration. Existing systems
must provision the reserved identity before enabling it. Check
the selected provider/features, musl targets, and required virtual CPU features
rather than assuming every VM CPU model can execute the binary.

Define service identity and minimum required privileges, persistent drift/state,
status reporting, initial step versus later slew policy, and recovery after VM
pause or clock jumps. The step policy is the `[synchronization]` table of
`ntp.toml`: `startup-step-panic-threshold` bounds the first step,
`single-step-panic-threshold` and `accumulated-step-panic-threshold` bound later
steps, and the daemon exits instead of exceeding them. Prove actual guest-clock discipline, not just daemon
startup or an NTS handshake. Never grant a test access to alter the build host's
clock; use disposable guests for clock-changing tests.

Disposable x86_64/KVM guests prove startup convergence from both clock directions,
the privilege boundary and supervised restart. External-backstep and QMP
pause/resume cases prove restart/source reselection; the backstep case does not
prove convergence, and the loopback oracle pauses with the guest. A controlled
NTS guest verifies CA/name and `ntske/1`, records rejection of tampered replies,
converges against the raw-clock oracle and restarts under supervision. Its
standalone runner passes end to end. Test-only chrony 4.9 agrees on startup
stepping in both offset directions and readiness before synchronization.
This comparison does not establish slew, NTS interoperability or reboot-policy parity.
The package now persists a bounded steady frequency correction and uncertainty,
excluding phase slew. A controlled 100 ppm source proves learning and restoration
across daemon restart and a fresh kernel boot on the same state disk. Restoration
is checked against the kernel frequency before any peer is available and while
stratum remains 16. The retained frequency shell runner passes both boots end to end on x86_64/KVM.
The final artifact also passes the authenticated NTS control.
The private state directory must belong to UID/GID 123 with mode 0700; invalid
state or a conflicting writer stops the daemon. This is oscillator calibration,
not a UTC floor or a power-loss durability proof.
An x86_64/KVM guest also selected the authenticated external `time.cloudflare.com` NTS source before and after supervised restart. This does not independently measure clock accuracy. aarch64 runtime qualification remains open. See the
[retained guest checks](TESTING.md#run-the-disposable-ntp-guest).

Qualify elapsed-time consumers alongside clock discipline. LAP-27 and XSH-35
separate supervisor deadlines from wall timestamps with explicit units/origins;
a mechanical `time.now()` to `time.monotonic()` replacement is not sufficient.
Correcting wall time must not break restart, readiness or shutdown budgets.

Time bootstrap is part of R4: TLS/NTS verification and release expiry cannot
assume an already trustworthy wall clock. Document initial clock assumptions,
any persisted lower bound, cold-boot/offline behavior, and explicit operator
recovery. An unauthenticated NTP result or a virtual RTC is not authenticated
time; do not silently disable TLS verification or accept expired metadata.
Repository snapshots and trust releases require v2 signed `issued-at` metadata.
Their durable floors retain the greatest authenticated publication time, never
a local wall-clock observation. Verification still requires trustworthy current
time from an RTC or operator at bootstrap; the update path never sets the clock.
Legacy metadata and observed-clock state fail closed and require trusted
reprovisioning that preserves generation floors. See [snapshot policy](PM.md)
and [trust policy](CERTIFICATE-TRUST.md). The packaged unauthenticated pool is
not an authenticated time source; the packaged default is now NTS-only.
The maintained profile runs `ntpd-rs` against `time.cloudflare.com`, `nts.netnod.se`
and `nts.time.nl` (three independent operators; two must agree). The owner asked for
PTB as the third operator, but a guest saw its NTS-KE succeed and every NTS poll go
unanswered, so NLnet Labs' `nts.time.nl` took its place. The cold-boot policy is
unchanged: a trustworthy RTC or operator-set time is still required, and the daemon
does not weaken TLS verification. The nftables output chain drops TCP 4460 and UDP 123
from every user except UID 123; it does not restrict the daemon's own egress, because
an NTS-KE server may name another NTP port.
Persisted guest state alone cannot prevent a hostile hypervisor from rolling
back both clock and disk; do not promise that threat model is covered.

**Acceptance:** controlled NTP/NTS peers, bad/absent peers, persisted restart,
a skewed cold boot, and pause/resume produce bounded, observable outcomes.
Record synchronization state separately from service readiness. Exercise the
chosen trust/expiry behavior at incorrect initial times as well as after sync.

## R3: Repairable storage and VM rescue

Do not promote the current superblock-only `fsck.ext4` into a recovery guarantee.
For persistent Linux VM disks, prefer packaging established filesystem tooling
such as `e2fsprogs` over inventing a general repairing checker in XSH. Retain the
native image creator only for its explicit, tested format. Do not silently
replace package-owned command paths or describe a journal-less image as journaled.

Define root versus mutable-state layout, supported filesystem features, offline
check/repair behavior, and when a failed check leaves the volume read-only.
Never automatically repair a mounted writable filesystem. The Asterinas backend
currently uses ext2: qualify its format and recovery path independently rather
than imposing Linux ext4 features it has not proved.

Provide an independent rescue guest/image able to inspect and repair or restore
a detached virtual disk even when that disk's XSH, PID 1, or package manager is
broken. Use serial access and the existing VM launcher; physical media boot and
new firmware support are not required. Keep rescue independent of the normal
VM's network, package manager, and ability to launch an SSH server.

**Acceptance:** on disposable copies, exercise dirty shutdown, controlled
metadata corruption, filesystem-full conditions, and unrecoverable damage.
Distinguish clean, repaired, and unrecoverable results; verify known file hashes
and metadata after recoverable cases. Boot the rescue environment independently
and restore an unusable virtual disk. Journaling is not a backup policy.

`e2fsprogs` builds `e2fsck` without a shell, and `system/rescue.xsh` classifies
a detached repair. A Linux x86_64/KVM rescue guest boots with a read-only root
and no network, repairs controlled free-block accounting damage, and verifies
the recovered payload hash. The rescue guest also works after both installed
generation images fail to execute PID 1. Further journaled-ext4 fixtures survive
SIGKILL of QEMU during writes and after filesystem exhaustion. Offline journal
replay preserves the synced payload and permissions in both cases. Independent
rescue also restores a known missing `/init` symlink on a disposable copy; the
host publishes it as a new generation and proves a healthy boot and fallback.
A separate raw ext4 publication fixture recovers the old record after a staged
write, an old complete record after an unsynced rename, and the new record after
a directory fsync. QEMU is killed at each point before a recovery boot. These VM
checks do not establish physical host-storage power-loss durability. On
Asterinas, `qualify.sh storage --backend both` pairs every case with Linux:
a VMM kill during writes keeps the fsynced payload, a full volume reports
`ENOSPC` without damage, an unclean volume is flagged for checking because a
writable mount now clears the clean flag and counts the mount (kernel
`2167b6eb3`), and a corrupted image is refused a writable mount and left
unchanged; host `e2fsck` classifies each image and every recoverable one boots
again with its payload hash and mode intact.
See the
[detached rescue proof](INSTALLER.md#detached-rescue-guest-proof).

## R4: Authenticate repository and trust delivery

The signed repository-snapshot boundary already exists in `pm/repo_snapshot.xsh`
and the verified remote-index path; [PM snapshot authentication](PM.md#snapshot-authentication)
owns the exact format and behavior. Do not restart this as a new signing protocol
or describe production clients as simply trusting an unsigned index.

Finish operational integration: provision the verification-key set through a
trusted image/first-boot channel, retain accepted generation/time state across
reboots, exercise rotation/revocation, and qualify the production fetch path
inside the installed guest. The fetch has a real Linux x86_64/KVM HTTP/reboot
proof with fixture keys, and the installed maintained image fetches, rejects
tampering and rejects rollback across reboots with first-boot-provisioned keys
(`tests/integration/repo_snapshot_installed.py`). Keep parser/size limits, expiry, rollback/freeze
handling, and publication consistency explicit. Existing metadata is not a claim
of full TUF role/threshold support; evaluate any extension against established
update-metadata designs rather than adding ad-hoc cryptography.

Client trust must not depend solely on the mirror's HTTPS certificate, an SSH
connection, or the same mutable source delivering its first verification key.
A release copied over SSH must still pass the selected production admission
policy; staging a file locally must not silently turn it into an unsigned
local-development exception. Keep offline/local development workflows explicit.
Never fall back from failed production verification to unsigned content.
Coordinate expiry with R2's time policy and R6's durable provisioning.

The signed certificate-release path already includes the production key
provisioning ceremony, `--from`/`--url` acquisition, immutable candidate
composition, atomic activation with journal recovery, and installer seeding,
with guest evidence in [certificate trust](CERTIFICATE-TRUST.md). A package-only
fixture key rotation now passes end to end. Real TLS tests prove XSH and
source-built Tailscale enforce intermediate-key distrust while retaining the
remaining root bundle. uv deliberately uses upstream prebuilt binaries and
remains outside SPKI policy enforcement. Keep admission, insecure-mode
restrictions and restart semantics in [certificate trust](CERTIFICATE-TRUST.md).

**Acceptance:** tampered objects/indexes, stale/replayed metadata, interrupted
publication, and missing/incorrect clocks fail according to the explicit policy
without damaging the installed generation. Reboot preserves the accepted trust
floor. Trust updates additionally prove reboot replay and power-cut recovery
without rolling back distrust (see [certificate trust](CERTIFICATE-TRUST.md)).
Prove key rotation and recovery. A trust update changes new admissions;
already-running services are restarted by the operator, not by a cutover layer.
Missing owner-held keys remain an external prerequisite; never invent production
credentials or commit private keys to satisfy a test.

**Status: acceptance met on Linux x86_64/KVM.** Each clause maps to a passing
host or guest test in the [R4 acceptance matrix](CERTIFICATE-TRUST.md#r4-acceptance-matrix),
including a guest repository key rotation and revocation with recovery, a power
cut after each trust-journal fsync, and fail-closed verification clocks. Open:
the installed maintained-image drill was not rerun, there is no aarch64 or
Asterinas guest run, and one of four `trust_guest.xsh` runs on a loaded host
failed without a captured cause.

## R5: Activate installed generations and roll back safely

This is the centerpiece after the first useful remote-administration slice.
PM remains the plan/build/compose boundary. Put system selection and lifecycle
coordination at the system/installer boundary instead of adding mutable package
post-install scripts. The host-side atomic `current` bundle pointer is a useful
foundation, not evidence of guest activation or boot fallback.

Bind installer/profile overlays into the generation identity and retain an
honest installed receipt; the installer currently removes receipts after
overlaying roots. Separate immutable payload from `/etc` policy, secrets,
identities, and mutable application data. Define configuration conflicts and
state migrations before promising that switching binaries rolls back a machine.

Specify a small state machine: verified candidate, durably staged candidate,
pending boot, health-confirmed current generation, and retained known-good
fallback. Serialize concurrent activation and protect current/pending/fallback
objects from garbage collection. Select kernel, root, and any bootstrap inputs
as a matching bundle. Reboot-based activation is sufficient initially; arbitrary
live replacement of PID 1 and running binaries is not required.

Expose an inspectable plan and operation status through the existing system
boundary, used identically by local and remote XSH callers. An SSH disconnect
after staging or requesting reboot creates an uncertain caller outcome, not
permission to repeat the mutation. Reconnect and reconcile the recorded state.
A second remote-only deployment engine is out of scope.

For the direct-kernel VM workflow, the launcher owns boot selection, bounded
boot attempts, and fallback while the guest reports its identity and health.
Define this host/guest contract rather than pretending the guest selects a
kernel the host has already supplied. Confirm the running receipt and declared
local/critical-service health, including remote administration where the profile
promises it. External Internet availability must not be the sole boot-success
condition. An unbootable guest cannot be responsible for its own rollback.

Distinguish operator-authorized rollback to a retained generation from accepting
stale remote metadata. Persist trust/revocation and anti-rollback state outside
ordinary OS rollback, and refuse a fallback that would violate the current
security policy. Define recovery when no retained generation is admissible.
State migrations must be backward-compatible, explicitly reversible, or marked
as preventing automatic rollback; protect user data rather than faking success.

**Acceptance:** install A, stage and boot B, verify the running receipt, and
commit B only after the declared health check. Reject tampered B; recover from
an unbootable B; inject termination and remote disconnect at staging, selection,
and confirmation boundaries; exercise concurrent requests, full disks, and GC.
Every recoverable case selects a complete admissible bundle with preserved
mutable state. Rescue still works when neither normal generation boots. Linux
and Asterinas results are recorded separately; Linux aarch64 is deferred pending
a macOS aarch64 host via Docker.

`tests/integration/g2_lifecycle.py` drives the integrated install, stage, two
bounded startup failures, fallback with preserved state, and a health-confirmed
commit through the same host APIs on one KVM guest, chaining
`activation_recovery.py` and `activation_ssh.py`. After fallback the host record
keeps current, fallback and policy and names the failed generation with the
attempts it consumed, until the next stage or confirmation clears it; the
launcher selection and the guest boot markers carry the same identity.

`system/activation.xsh` records install, stage, pending boot, guest health
confirmation, and fallback after two attempts. Versioned activation records bind
health reports to a persistent pending-boot sequence. `system/activation.xsh`
publishes complete kernel/disk bundles atomically and verifies their receipts and
hashes before admission; the launcher verifies them before consuming an attempt.
The maintained guest keeps `/etc`, `/home`,
and `/var` on a separate private state disk and captures its immutable running
receipt before mounting that state.

Linux x86_64/KVM evidence now includes a distinct A-to-B root transition, a
PID-1-requested reboot, a matching running-generation/critical-service report,
and a host health commit of B with A retained. Identity survives on the separate
state disk. An earlier guest proof exercised two actual unbootable-B panics and
launcher fallback to healthy A. Host tests additionally cover termination at
both record fsync boundaries, concurrent staging and collection, full-filesystem
recovery, and reconciliation after losing a reply. Independent rescue boots
even when both generation images lack PID 1. A maintained guest additionally stages B through host APIs over pinned native
SSH. The client disconnects while the `activation.next` fsync is delayed, and
reconnect verifies state, hashes, duplicate-stage rejection and launcher selection.
The fixture rejects existing activation state and clears stale markers. This does
not establish physical power-loss behavior or add an installed activation command. Host admission policy
now pins complete generation identities, image hashes, and the supported shared
state contract. Its revision survives confirmation and fallback; revoked inputs
cannot be selected or confirmed. Incompatible state declarations are refused,
with no automatic migrations. Signed input delivery and TLS consumer distrust
remain the separate R4 boundaries.
See [maintained activation](QEMU.md#maintained-vm-activation) for the contracts.

## R6: Separate disposable development from long-lived VM policy

Start this track alongside R1/R2: a secure, reachable first boot and useful SSH
administration are the first user-visible increment toward G2. Keep current
autologin/passwordless-doas conveniences in an explicitly selected development
profile, not as an implicit policy for unattended reachable VMs. Preserve that
convenient development profile; do not silently change its intended behavior.

### First-boot identity and access

Use one small typed first-boot input for the selected hostname, operator account,
authorized public keys, network mode, repository trust provisioning, and optional
Tailscale enrollment. Validate it before mutation and make restart/reapplication
behavior explicit. Keep secrets in a separately provisioned, access-controlled
channel, never in public images, source, plans, or logs. No cloud-init clone or
plugin ecosystem is required.

Create or securely provision unique host keys and persistent machine identity;
do not regenerate them on every boot. Establish the administration client's
host-key trust through an explicit channel rather than silently accepting the
first network answer. Define rotation, failed/partial first boot, and the
identity distinction between restore and clone. Preserve an independent local
rescue route when provisioning or remote access fails.

nftables and Dropbear already exist; the gap is policy and lifecycle integration,
not another firewall or login-server implementation. Apply a tested profile-owned
firewall before exposing listeners, handle failed ruleset updates atomically,
and define Tailscale coexistence without accidentally removing recovery access.
Use least-privilege service execution and explicit doas delegation where needed.
No shared default passwords, implicit root login, or globally writable session
state is justified by unattended setup.

### SSH-native XSH administration

Coordinate with [XSH's remote-execution roadmap](https://github.com/laputa-systems/xsh/blob/master/docs/ROADMAP.md#next-capability-ssh-native-remote-xsh).
XSH owns reusable typed execution, stream, host-key, and file-transfer boundaries;
Laputa owns a small administration library over the existing PM, xinit, network,
and system-report owners. Do not create a generic Ansible replacement, a second
service schema, or a mandatory resident fleet agent inside Laputa.

The transport is XSH's native Graviola/OxiSH-backed client
([XSH-55](https://github.com/laputa-systems/xsh/blob/master/docs/rfc/XSH-55-native-ssh-client.md)),
which never invokes an external `ssh`. The OpenSSL-less client in
[ssh-build](https://github.com/laputa-systems/ssh-build) is its test oracle, not
a production fallback. The client has landed in XSH (experimental) and
[remote administration](REMOTE-ADMIN.md) uses it for one headless VM. The
current OxiSH server is Git-only, not a general
login/PTY/SFTP server. Keep Dropbear until a separately qualified server has a
concrete benefit; a server rewrite is not a dependency of G2.

[xsh-infra](https://github.com/laputa-systems/xsh/blob/master/docs/rfc/XSH-56-xsh-infra.md)
is a separate pyinfra-inspired tool over the same client, for hosts without a
remote XSH runtime. Laputa does not depend on it, its OpenRC adapter does not
bring OpenRC into Laputa, and any Laputa service adapter it adds goes through
the existing xinit contract.

Use a fixed reviewed remote dispatcher with bounded versioned structured input,
not request values interpolated into shell source. `system/remote.xsh` and
`system/remote_guest.xsh` implement it for one x86_64 VM; see
[remote administration](REMOTE-ADMIN.md) for what the drill proves and omits. Preserve byte streams,
explicit remote status, deadlines, backpressure, and cleanup. Keep file staging
and digest verification separate from artifact authenticity. Unknown outcomes
must be inspectable and reconciled, not automatically replayed. A closed SSH
channel does not by itself prove a remote process or mutation stopped.

Read-only generation/service/network inspection and redacted support collection
should work without blanket root authority. Mutating operations use the same
local validation and privilege boundaries as console administration. Keep the
public API small until the one-VM consumer establishes what it actually needs.

Check the actual VM kernel configuration before claiming sandboxing. Historical
kernel audits found seccomp/namespaces gaps; recheck the selected configuration
rather than treating old findings as current evidence. Add only capabilities
required by selected services or R8, with explicit failure on unavailable
enforcement. Address service resource limits as needed; never treat ignored
fields or a macOS no-op as Linux enforcement.

**Acceptance:** a fresh long-lived VM reaches authenticated, host-key-verified
SSH without manual repair and without unintended autologin, shared credentials,
or listeners. From a separate machine, inspect the running generation/services,
run a controlled XSH operation, and stage a verified artifact. Test bad host keys,
reboot with stable identity, partial provisioning, network loss, and disconnect
after a mutation; preserve recovery access and do not duplicate side effects.
Selected privilege/isolation limits are verified inside the guest. Service
control from the non-root operator uses the `xinit-admin` group's supervisory
verbs (`start`, `stop`, `restart`, `reload`) and does not require doas or a root
login. The development profile remains convenient and visibly distinct.

`qemu-maintained` sets `development` false; the other profiles set it true and
keep their roots. First boot is validated before any write, Dropbear keeps one
ed25519 host key, and the nftables package installs the filter ruleset whose
oneshot fails closed when the file is absent. Linux x86_64/KVM guests boot and
reboot with stable operator files and host identity; missing or rejected
firewall rules keep Dropbear down. New operators use `/usr/bin/xsh-login`.
Native SSH also passes the interrupted activation-stage recovery drill described
in [maintained VM activation](QEMU.md#maintained-vm-activation). These checks do
not qualify macOS or aarch64 clients. XSH-55 owns the SSH client's wider matrix.

## R7: Backups, timers, and persistent diagnostics

**Backups.** `packages/rustic` pins v0.11.4. The retained manual restore drill
backs up `/etc /home /var`, reconstructs static state from the maintained image,
restores a blank disk and checks identity, supervised networking, repository
integrity and re-backup differences. It removes the first repository key and
proves that its password fails while the second key and exported masterkey each
recover access. A fresh receipt-bound guest passed this drill with a previously
extracted packaged rustic binary and restic 0.18.1; fresh rustic artifact metadata
was unavailable, so this does not establish a fresh package provenance check.
Five harness regressions cover stale and interleaved console output and missing
or failed proof markers. Scheduling, retention, remote backends and a packaged
restic remain open. The existing `laputa-systems/fs`
copy/sync utility is not a substitute for retained backups. Define encryption-key
recovery, retention, repository checking, application quiescence, and which state
is restored versus reconstructed from package generations. Distinguish restoring
a machine's identity from creating a clone. Prove a manual restore before
scheduling unattended backup or pruning. An actual blank-disk restore, not a
successful backup command, is the G2 acceptance result.

**Timers.** Prefer a small supervised XSH scheduler using xinit to own jobs, not
a second init system or a mandatory new subsystem inside PID 1. Specify interval
versus calendar time, overlap policy, missed-run/coalescing behavior, persistence
across reboot, cancellation, bounded retries, and inspectable last/next results.
Handle wall-clock corrections and VM pause explicitly. Do not promise exactly-once
side effects across crashes; use idempotent jobs or explicit reconciliation.
Scheduling is a follow-up to working manual maintenance, not an entry fee for
remote inspection, diagnostics, or restore.

**Diagnostics.** Roll out the implemented XSH syslog service through xinit and
extend its existing log path rather than replacing it. Reuse XSH's system-report
collectors for bounded, redacted local/remote support bundles. Capture persistent
kernel/boot/service events, generation and boot identity, lease changes, and
activation/failure history with useful timestamps even before wall-clock sync.
Document copy-truncate and datagram loss semantics rather than promising lossless
logs. Bound storage, handle disk-full failure, and exclude secrets. No fleet
observability platform, journald imitation, or per-service logger architecture
is required. Basic diagnostics arrive before update-failure tests, not after G2.

**Diagnostics status: forced-reboot acceptance met on Linux x86_64/KVM.**
`packages/laputa-diagnostics` adds a boot oneshot that writes a bounded event
log, boot history, lease summary and redacted support bundle to
`/var/log/diagnostics` ([QEMU](QEMU.md#persistent-diagnostics)).
`tests/integration/diagnostics_reboot.py` forces a generation fallback and
checks that the store names the failed generation and its service history,
stays bounded through ENOSPC, and holds no seeded secret. Open: no profile
selects the package yet, and it does not reuse the XSH system-report collectors.

**Acceptance:** restore selected mutable state and a bootable system onto a blank
virtual disk from backup plus trusted artifacts, without relying on the original
VM. Test missed/overlapping jobs and clock changes without duplicate uncontrolled
runs when scheduling is introduced. After a forced reboot, diagnostics identify
the failed generation and service history, stay within retention bounds, and
exclude secrets.

## R8: Optional Linux OCI execution

After the operational baseline, evaluate `youki` as a Rust OCI runtime candidate.
First define a Linux guest kernel/userspace capability matrix for namespaces,
cgroups v2, seccomp, mounts, networking, and rootless UID/GID mappings where
rootless operation is actually promised. Prove one constrained OCI workload,
cleanup after failure, and resource/isolation enforcement before discussing a
container management stack. Do not equate an OCI runtime with Docker compatibility.

Keep this an opt-in VM profile. It must not enlarge the default runtime closure
or become a prerequisite for ordinary Laputa services. Asterinas OCI support is
not part of this milestone; separately scope any required kernel work under the
existing no-workaround rule.

## R9: Selectively package existing native tools

Evaluate `e`, `tm`, `fs`, and `srv` from the Laputa organization where an installed
VM workflow needs them. Add pinned recipes, runtime closures, behavior proofs,
and a deliberate profile selection; do not install everything by default or
silently replace existing providers. For example, qualify editor save fidelity
before making it the rescue/configuration editor, and keep diagnostic HTTP
serving opt-in rather than starting a listener automatically.

Treat `ntpd-rs` as R2's operational dependency, not optional catalog expansion.
Defer `zzz` and other physical power/device integration under the scope boundary.
Rust implementations are preferred where they fit, but reliability at storage,
security, and protocol boundaries outranks avoiding every non-Rust dependency.
Additional utility ports and desktop features do not hold G2 hostage.

## R10: Close the self-hosting loop

The [existing self-hosting workflow](SELF-HOSTING.md) already describes a bounded
Linux x86_64 development proof: rebuild XSH/xsht in guest A, use the replacement
tools for a C/Rust/XSH cohort and successor bundle, boot B, verify its actual
receipt/runner hashes, and boot the unchanged A again. Preserve and reuse it;
do not launch a second self-hosting campaign as though no foundation exists.

The next step is to make that loop routine: change XSH or an in-tree component
inside Laputa, rebuild the affected package with declared inputs, stage the
successor through R4/R5, and reboot with the same confirmation/fallback contract
used for remotely supplied updates. Keep the compiler in Rust; this is
distribution self-hosting, not language self-implementation.

The xsh package's seed products and package-tools' external host-tools base
remain declared bootstrap boundaries. The current successor proof reuses the
kernel artifact and is not a claim of complete source bootstrap, production
remote admission, automatic promotion, or a fully self-hosted world. Do not make
a whole-world rebuild an entry fee for a useful one-package feedback loop.

Maintain the closed cohort's declared tools, libraries, sources, environment,
and writable paths, plus explicit seed exceptions. No network or ambient host
fallback should silently satisfy a missing input. Poison undeclared inputs and
test OS-enforced authority separately from output reproducibility. LAP-10 owns
independent rebuild comparisons; LAP-31 owns semantic executor invalidation.
Executor provenance alone cannot stop reuse after an interpreter change alters
recipe meaning. Retain the completed cohort/successor regressions while expanding
only the slice needed by the installed workflow.

**Acceptance:** one qualified installed target builds its replacement tools or
selected in-tree package, produces a successor using the normal PM, and activates
it through the normal system/launcher path. Verify the actual running receipt
and behavior, preserve the prior system and mutable state on failure, and name
remaining bootstrap inputs. Keep local development admission distinct from
production R4/R5 trust. Linux and Asterinas require separate evidence; Linux
aarch64 remains deferred pending a macOS aarch64 host via Docker.

## R11: Typed activation and per-user agents

Deferred until G2 and G4 pass. Earlier, a single trigger is admitted only when a
concrete G2 workflow needs it.

xinit already owns supervision, readiness, and restart. R11 adds the event side
of the launchd model to the same typed service model, not a second manager:

- **Socket activation:** xinit holds the listening socket and passes it to the
  service on first connection, so idle services need not run at boot.
- **Path, timer, and device triggers:** start a service when a path changes, a
  calendar or monotonic deadline passes, or mdevd reports a device.
- **Per-user agents:** a user's own services, declared in their home directory
  and supervised without root, as systemd user units and launchd agents are.
- **Process-tree ownership:** cgroup v2 groups instead of process groups, so
  stopping a service stops every descendant and resource limits apply to the
  whole tree.

Service descriptions stay ordinary typed XSH. A malformed trigger is a
`xsht check` failure, not a boot-time surprise. Each trigger needs one XSH
substrate primitive (descriptor passing, inotify, timerfd, pidfd, cgroup v2
control); add each primitive with its consumer, never as a speculative
collection. Checked effects remain distinct from OS authority enforcement.

**Acceptance:** an idle socket-activated service is absent until its first
connection and then serves it without a lost request; a timer and a device
trigger fire exactly once per event across an xinit restart; killing a service
stops all of its descendants; a user agent starts and stops without root.

## R12: A complete Wayland desktop on one reference laptop

Deferred until R11 passes. Name one reference laptop; do not target laptops in
general. Real-hardware enablement stays out of scope until the owner admits
this track.

A desktop is mostly hardware and compatibility work, not service glue: GPU/KMS
and Mesa, Wi-Fi firmware, suspend and resume, ACPI battery, backlight and lid
events, PipeWire audio, Bluetooth, and display hotplug. Applications also
assume a D-Bus session and system bus and logind-shaped session and power
interfaces (portals, notifications, inhibitors); seatd covers only seat access.
Keep that compatibility surface as small as the reference applications need,
and put it behind typed XSH interfaces so each owner stays separate rather than
absorbed into one project. Memory-pressure handling uses PSI and cgroup policy;
Linux applications cannot be assumed to cooperate the way macOS applications
do.

**Acceptance:** on the reference laptop, the installed system boots to the
in-tree compositor, joins Wi-Fi, suspends and resumes repeatedly without losing
the session, reports battery and controls backlight, plays audio, runs a
browser with working portals, and rolls back a bad update through R5.

## Long-term: reduce C and C++ in the userspace

After the active campaign, Play's SRT/Core Text migrations, and
[shared rust-fontconfig adoption](rfc/LAP-52-rust-fontconfig.md), pursue a
Rust/XSH/Zig-owned desktop and system layer. Start with a measured census and
finish existing seatd-client, keyboard, and Wayland interfaces. Qualify the
distribution compression providers and then HarfRust and Swash/Skrifa/Zeno
against the working [shared font baseline](FONT-STACK.md). Existing OxiSH,
KBVM, and XSH Rust compression backends are foundations, not new adoptions.

Keep `ffmpeg-build` as the maintained native media dependency. FFmpeg and codec
replacement are explicitly out of scope; Play subtitle, typography, OSD, and
application work remain separate. Retain Mesa, musl, and Linux. Crabc evaluation
or adoption, allocator work, runtime/kernel replacement, and GPU-driver rewrites
are excluded. Hardware enablement stays deferred. The
[follow-on design](rfc/LAP-51-c-free-userspace.md) records these boundaries and
lower-confidence research. LAP-52 precedes LAP-51's bounded census. This
direction launches no new pilot and changes no current acceptance gate.

## Delivery gates and evidence

| Gate | Required result |
|---|---|
| G0: Qualified baseline | Record exact source/seed/kernel/profile inputs and runnable existing proofs. Preserve the in-tree userland regressions and recheck historical TODO gaps against current topic evidence. Linux aarch64 qualification remains separately reported; missing proof is not a pass. |
| G1: Reliable VM | R1-R3 work together with controlled network/time failure, daemon recovery, dirty-disk handling, independent rescue, and enough persistent diagnostics to explain failures. |
| G2: Remotely maintainable VM | Pass the integrated provision/SSH/inspect/stage/fail-B/recover-A/confirm/blank-disk-restore scenario above using R4-R7 and the G1 foundation. |
| G3: Optional expansion | R8/R9 are admitted only with a concrete workload, bounded runtime cost, and their own proof; they do not hold G1/G2 hostage. |
| G4: Self-hosted feedback loop | R10 connects the existing cohort/replacement-XSH/successor proof to normal activation on a named target; it can advance independently of optional expansion and does not waive G1/G2. |
| G5: Reference-laptop desktop | Last. R11 and then R12 pass their acceptance after G2 and G4; neither delays an earlier gate. |

Use focused tests first and the existing [testing](TESTING.md) and
[development](DEVELOPMENT.md) entry points. Reserve `make verify` for an explicitly
requested full verification run. No full rebuild is required for roadmap-only
edits. Add targeted guest fixtures to the existing harness instead of a second
VM orchestration framework. Fault injection uses disposable guests and disks,
never host clocks, host disks, or production credentials.

Prefer failures that become small counterexamples: LAP-34 and XSH-40 connect one
real service lifecycle failure to a hermetic native replay before generalizing.
Missing observations must not fall through to the host. Process kills do not
simulate loss/reordering of storage writes; storage crash claims need separate
fault injection. The QMP helper was replaced only through a reusable bounded
XSH client with parity, not a language-only translation or a new VM framework.
LAP-33/XSH-37 qualify confined extraction/publication without equating lexical
path safety with authority. Existing production/test boundaries remain binding.

For every completed slice, record the source revision, target/backend, relevant
configuration and dependency closure, test commands/results, and remaining
limits. Linux aarch64, Linux x86_64, and Asterinas x86_64 have separate evidence;
Linux aarch64 evidence is deferred pending a macOS aarch64 host via Docker;
a build-only result is not a boot proof. Fix required Asterinas syscalls in the
pinned fork with regression tests, never hide a failure behind a userspace shim
or mark a skipped test as passed. A Linux-first delivery may land while the
Asterinas result remains explicitly unsupported or unverified.

Keep reproducibility and update visibility tied to LAP-10/LAP-11/LAP-12 instead
of creating parallel queues. Stable artifact keys alone do not prove byte-for-byte
rebuilds. When implementation changes a contract, update its owning topic document
and retire the corresponding roadmap gap; leave operational detail out of this
file. Broaden scope only by an explicit owner decision.
