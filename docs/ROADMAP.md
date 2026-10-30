# Roadmap

Make Laputa a small, reproducible, XSH-managed operating system that can remain
useful unattended: a VM should survive service crashes, network loss, interrupted
updates, and virtual-disk damage, with an inspectable recovery path.

After the in-tree tinyland, mdevd-rs, seatd-rs, and doas-rs integration is
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
| Native userland | In-tree tinyland, mdevd-rs, seatd-rs, and doas-rs with package inputs and retained tests | Qualify the exact packaged chain, normal boot ownership, and regression coverage; consolidation alone is not a security or release claim. See [tinyland](TINYLAND.md). |
| Packages and images | Typed plans, immutable artifacts, runtime-only generations, atomic publication of host-side system bundles | Installed-system activation, boot success, rollback, and state ownership are not the same as composing a generation. See [PM](PM.md) and [core infrastructure](CORE-INFRASTRUCTURE.md). |
| Services | xinit scanning, readiness, restart backoff, control, and rotating stdout/stderr | Keep normal boot, tested recovery, and supervisor ownership aligned. See [init](../xinit/docs/INIT.md) and [supervision](../xinit/docs/SUPERVISION.md). |
| Remote administration | Packaged Dropbear and an installer/SSH proof | Typed XSH remote execution, persistent identity, first-boot provisioning, and one inspect/stage/recover workflow remain the next integration milestone. |
| Storage | Native image/installer filesystem tools | Installer `mkfs.ext4` is journal-less and `fsck.ext4` does not repair. See [installer](INSTALLER.md). |
| Networking and logging | XSH records supervised DHCPv4 and syslog (XSH-53/54) as implemented; Laputa has network policy, xinit, Dropbear, Tailscale, and nftables foundations | Adopt matching XSH products, roll out the services, and qualify leases/resolver ownership, time, and persistent logs in the installed image. See [XSH roadmap](https://github.com/laputa-systems/xsh/blob/master/docs/ROADMAP.md). |
| Trust | Signed repository snapshots plus signed certificate releases and system distrust policy | Provision repository verification keys and durable accepted state; prove the production guest fetch path and consumer-specific enforcement. See [PM](PM.md#snapshot-authentication) and [certificate trust](CERTIFICATE-TRUST.md). |
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

Bounded slices can overlap. Design R4 alongside R2's clock-bootstrap policy;
R5 depends on R3's rescue path and R4's authenticated inputs. R10 can continue
independently, but must not delay a useful remote/operational baseline or be
presented as a substitute for production trust, state ownership, and fallback.
Defer broad OCI work, desktop protocol expansion, additional utility ports,
and firmware-boot work unless a concrete G2 workflow requires them.

## G2: The remotely maintainable VM

**Status: planned.** This is the organizing product milestone, not a new manager,
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

### Time discipline and bootstrap

Integrate the separately developed `laputa-systems/ntpd-rs` fork as a pinned
package and xinit service. Its Graviola work belongs upstream in that repository;
this roadmap does not claim the port or Laputa integration is complete. Check
the selected provider/features, musl targets, and required virtual CPU features
rather than assuming every VM CPU model can execute the binary.

Define service identity and minimum required privileges, persistent drift/state,
status reporting, initial step versus later slew policy, and recovery after VM
pause or clock jumps. Prove actual guest-clock discipline, not just daemon
startup or an NTS handshake. Never grant a test access to alter the build host's
clock; use disposable guests for clock-changing tests.

Qualify elapsed-time consumers alongside clock discipline. LAP-27 and XSH-35
separate supervisor deadlines from wall timestamps with explicit units/origins;
a mechanical `time.now()` to `time.monotonic()` replacement is not sufficient.
Correcting wall time must not break restart, readiness or shutdown budgets.

Time bootstrap is part of R4: TLS/NTS verification and release expiry cannot
assume an already trustworthy wall clock. Document initial clock assumptions,
any persisted lower bound, cold-boot/offline behavior, and explicit operator
recovery. An unauthenticated NTP result or a virtual RTC is not authenticated
time; do not silently disable TLS verification or accept expired metadata.
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
Host-storage power loss and independent Asterinas qualification remain unproved.
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
inside the installed guest. Keep parser/size limits, expiry, rollback/freeze
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
with guest evidence in [certificate trust](CERTIFICATE-TRUST.md). Remaining:
exercise a key rotation end to end and track each TLS consumer's actual
enforcement; sharing a root file does not prove support for XSH's intermediate-key
blocklist. Keep trust policy semantics in that topic document.

**Acceptance:** tampered objects/indexes, stale/replayed metadata, interrupted
publication, and missing/incorrect clocks fail according to the explicit policy
without damaging the installed generation. Reboot preserves the accepted trust
floor. Trust updates additionally prove reboot replay and power-cut recovery
without rolling back distrust (see [certificate trust](CERTIFICATE-TRUST.md)).
Prove key rotation and recovery. A trust update changes new admissions;
already-running services are restarted by the operator, not by a cutover layer.
Missing owner-held keys remain an external prerequisite; never invent production
credentials or commit private keys to satisfy a test.

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
even when both generation images lack PID 1. These proofs do not establish
power-loss durability, native SSH disconnect behavior, trust-policy enforcement
across rollback, or state migration acceptance.
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
a production fallback. XSH's roadmap schedules that client after its active
campaigns close. The current OxiSH server is Git-only, not a general
login/PTY/SFTP server. Keep Dropbear until a separately qualified server has a
concrete benefit; a server rewrite is not a dependency of G2.

[xsh-infra](https://github.com/laputa-systems/xsh/blob/master/docs/rfc/XSH-56-xsh-infra.md)
is a separate pyinfra-inspired tool over the same client, for hosts without a
remote XSH runtime. Laputa does not depend on it, its OpenRC adapter does not
bring OpenRC into Laputa, and any Laputa service adapter it adds goes through
the existing xinit contract.

Use a fixed reviewed remote dispatcher with bounded versioned structured input,
not request values interpolated into shell source. Preserve byte streams,
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
Selected privilege/isolation limits are verified inside the guest. The
development profile remains convenient and visibly distinct.

`qemu-maintained` sets `development` false; the other profiles set it true and
keep their roots. First boot is validated before any write, Dropbear keeps one
ed25519 host key, and the nftables package installs the filter ruleset whose
oneshot fails closed when the file is absent. No fresh VM boot has been run.
The SSH client remains XSH-55.

## R7: Backups, timers, and persistent diagnostics

**Backups.** Select an established versioned backup tool; `rustic` is a candidate
to qualify, not an already-approved default. The existing `laputa-systems/fs`
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

## Delivery gates and evidence

| Gate | Required result |
|---|---|
| G0: Qualified baseline | Record exact source/seed/kernel/profile inputs and runnable existing proofs. Preserve the in-tree userland regressions and recheck historical TODO gaps against current topic evidence. Linux aarch64 qualification remains separately reported; missing proof is not a pass. |
| G1: Reliable VM | R1-R3 work together with controlled network/time failure, daemon recovery, dirty-disk handling, independent rescue, and enough persistent diagnostics to explain failures. |
| G2: Remotely maintainable VM | Pass the integrated provision/SSH/inspect/stage/fail-B/recover-A/confirm/blank-disk-restore scenario above using R4-R7 and the G1 foundation. |
| G3: Optional expansion | R8/R9 are admitted only with a concrete workload, bounded runtime cost, and their own proof; they do not hold G1/G2 hostage. |
| G4: Self-hosted feedback loop | R10 connects the existing cohort/replacement-XSH/successor proof to normal activation on a named target; it can advance independently of optional expansion and does not waive G1/G2. |

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
fault injection. LAP-35 replaces the QMP helper only through a reusable bounded
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
