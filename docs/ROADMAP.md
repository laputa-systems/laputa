# Roadmap

Make Laputa a small, reproducible, XSH-managed operating system that can remain
useful unattended: a VM should survive service crashes, network loss, interrupted
updates, and virtual-disk damage, with an inspectable recovery path.

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

The most direct feedback loop is to build XSH inside Laputa, use it to produce a
successor system, and reduce discovered failures to ordinary regression tests.
R10 adds that milestone; R1/R2/R4/R5 remain the operational consumers that give
its abstractions purpose. No new language feature is justified solely by this
roadmap, and no paused XSH campaign is resumed by it.

## Authority and scope

This document owns direction, sequencing, and acceptance milestones.
[TODO](../TODO.md) owns bounded defects and follow-ups; the topic documents linked
below own current behavior. A roadmap entry is planned work, not a claim of
implementation or permission to launch every workstream. Before implementation,
recheck the source, choose a bounded slice, and record its acceptance evidence in
the owning topic or campaign. Do not duplicate the TODO queue here.

The planning baseline was reread after the documentation refactor at
`44572a718e3067e9d03e6646036e67f04c4ac5b2` on 2026-10-25. This review did not
rerun build or guest proofs. All milestones below remain open unless their
owning documentation records subsequent verification. The systems-foundation
follow-up used Laputa `85c175515312` and XSH `9d893e0075d2`; it adds design
constraints and TODO slices, not new runtime evidence.

**Supported direction:** Linux guests under QEMU on aarch64 and x86_64, plus the
pinned x86_64 Asterinas/Firecracker backend. Keep the existing graphical VM
reference working while developing the headless operational path. A feature
proved on Linux is not automatically proved on Asterinas or another architecture.
Native build hosts are test infrastructure, not a bare-metal Laputa target.

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

## Baseline: foundations are not missing

| Area | Existing foundation | Remaining boundary |
|---|---|---|
| Packages and images | Typed plans, immutable artifacts, runtime-only generations, atomic publication of host-side system bundles | Installed-system activation, boot success, rollback, and state ownership are not the same as composing a generation. See [PM](PM.md) and [core infrastructure](CORE-INFRASTRUCTURE.md). |
| Services | xinit scanning, readiness, restart backoff, control, and rotating stdout/stderr | Boot paths mix service definitions and direct launches; integrated lifecycle ownership still needs proof. See [init](../xinit/docs/INIT.md) and [supervision](../xinit/docs/SUPERVISION.md). |
| Storage | Native image/installer filesystem tools | Installer `mkfs.ext4` is journal-less and `fsck.ext4` does not repair. See [installer](INSTALLER.md). |
| Networking | `laputa-net`, XSH interface tools, Dropbear, Tailscale, and nftables packages | The audited XSH `ifup` acquires an IPv4 DHCP lease once; continuous lease management and coordinated resolver state are not established. |
| Trust | System roots, XSH distrust policy, and signed trust-release verification/composition | Trust release acquisition, production key provisioning, activation, and consumer cutover remain incomplete. See [certificate trust](CERTIFICATE-TRUST.md). |
| Verification | Package tests, installer/SSH and graphical QEMU proofs, pinned Asterinas guest tests | Existing smoke proofs do not establish long-lived operation, recovery, or platform parity. See [testing](TESTING.md), [QEMU](QEMU.md), and [Asterinas](ASTERINAS.md). |

The baseline is deliberately narrow. A package name, successful `--version`,
content-addressed artifact, or boot marker is not evidence that the corresponding
operational capability is complete.

## Priority and sequence

P0 means required before trusting a long-lived installed VM; P1 strengthens the
operational and self-hosting foundation; P2 is optional expansion. Priority is not
execution order: service ownership and focused tests unblock several P0 tracks.
These milestone priorities are not a renumbering of the bounded TODO priorities.

| Track | Priority | Outcome |
|---|---|---|
| R1 | P1, start first | One supervised boot service graph with honest readiness and failure behavior |
| R2 | P0 | Persistent VM networking and disciplined time |
| R3 | P0 | Repairable virtual disks and an independent rescue path |
| R4 | P0 | Authenticated repository/trust delivery with explicit freshness policy |
| R5 | P0 | Installed-system generation activation and bounded rollback |
| R6 | P1 | A safe long-lived VM profile distinct from disposable development images |
| R7 | P1 | Backups, scheduled maintenance, and persistent diagnostics |
| R8 | P2 | A qualified Linux OCI execution profile, only after the operational baseline |
| R9 | P2 | Selective integration of Laputa-native tools, not catalog growth for its own sake |
| R10 | P1, staged independently | Closed build cohort, in-guest XSH rebuild, and successor-system boot |

R1, R2, and R3 can advance in bounded independent slices. Design R4 alongside
R2's time-bootstrap policy; R5 depends on R3's rescue path and R4's authenticated
inputs. Basic diagnostic capture and manual backup/restore should arrive early;
R7's automation is not a reason to delay them. No implementation needs to wait
for the whole roadmap to be complete. R10 can progress alongside those tracks;
it is not an entry fee for their bounded fixes, and its local development proof
is not a substitute for R4/R5 production trust and activation.

## R1: Make xinit the service lifecycle owner

Use one long-lived scanner for the selected boot graph, launched and supervised
by PID 1. Keep early mounts and host-independent setup in boot hooks; move
persistent daemons out of bespoke foreground/background boot scripts. Keep the
inittab engine and service scanner's distinct responsibilities documented rather
than merging them solely for code reuse.

Audit `packages/baselayout/files/rootfs/etc/inittab`, the installer's generated
inittab, profile boot hooks, and installed service modules together. The graphical
hook directly launches daemons while other paths use service definitions; that
is an ownership inconsistency, not proof of an observed concurrent duplicate.
Prevent duplicate instances and conflicting scanner ownership when paths converge.

Reject unknown top-level and nested service fields and conflicting log settings
(LAP-5). Define startup-critical readiness failure separately from process
liveness: today's notify timeout can leave a service `running` but not ready.
A named facility without a provider must not masquerade as a satisfied critical
dependency. Keep local network configuration distinct from Internet reachability;
do not block rescue/login forever waiting for external services. Longruns must
remain foreground processes. Do not add blanket dependency restart cascades.

Give service configuration one authoritative typed model, with shape validation,
semantic checks and execution preconditions kept distinct. LAP-5 owns strict
normalization, redacted inspection and read-only planning. Reuse XSH's data
validator for external configuration; executable service modules remain trusted
code, not inert data. A codec migration must not create a second service schema.

**Acceptance:** a real VM boots the selected graph once; killing a daemon
exercises backoff and recovery; killing/restarting the scanner has a defined
cleanup/recovery path without duplicate children; malformed config and failed
readiness produce explicit status. Reboot stops owned services before filesystem
shutdown. Existing xinit proofs and the graphical reference remain valid.

## R2: Persistent VM networking and time

### Network lifecycle

Keep XSH as the configuration/control layer; give a persistent supervised client
ownership of DHCP leases. The audited `core/ifup.xsh` in the XSH repository has an
initial IPv4 handshake, direct `/etc/resolv.conf` writes, and no lease renewal
loop; it rejects non-`inet` configuration. Do not mistake this for a complete
network manager or infer that the kernel lacks IPv6.

Define renewal, rebinding, expiry, NAK handling, restart with saved leases, link
loss, and virtual NIC reappearance. Remove expired addresses/routes and reconcile
state after VM pause/resume. Start with one supported virtual Ethernet path.
Add explicit IPv6 policy and tests for SLAAC/router advertisements and resolver
information before claiming dual-stack support; add DHCPv6 where the selected
profile requires it. Wi-Fi remains excluded.

Give resolver configuration one owner, atomic updates, and per-interface state.
Define how DHCP, static settings, and Tailscale coexist, including the supported
split-DNS boundary; do not let independent writers race on `resolv.conf`.
Keep name resolution separate from optional DNS caching/recursive service work.
Audit hook execution for the intended XSH/no-ambient-shell contract.

Use the network path as a shared-library consumer: observe actual state, compute
a typed plan, apply with preconditions, then re-observe. Preserve foreign resources,
including Tailscale/operator state; detect lost notifications and stale snapshots.
Partial application requires reconciliation, not a promise of generic rollback.
LAP-32 owns the first virtual-interface slice with XSH-38's reusable operations.

Evaluate a maintained DHCP client before writing a new one. `dhcproto` is a
possible Rust protocol building block, not a ready-made lease manager. Select an
implementation only after reviewing its lifecycle behavior, musl dependency
closure, and tests; Rust alone is not an acceptance criterion.

**Acceptance:** use a controlled local DHCP/DNS server with short leases in VM
fixtures. Exercise renew/rebind, NAK/expiry, changed DNS/routes, daemon restart,
link loss, and pause/resume without duplicate or stale configuration. Boot and
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
new firmware support are not required.

**Acceptance:** on disposable copies, exercise dirty shutdown, controlled
metadata corruption, filesystem-full conditions, and unrecoverable damage.
Distinguish clean, repaired, and unrecoverable results; verify known file hashes
and metadata after recoverable cases. Boot the rescue environment independently
and restore an unusable virtual disk. Journaling is not a backup policy.

## R4: Authenticate repository and trust delivery

`pm/remote.xsh` currently fetches and parses mutable `index.json`; artifact
hashes and mirror publisher authentication do not independently authenticate
that index to a client. Preserve content-addressed objects while adding a
versioned, signed release/snapshot boundary binding the exact index and referenced
artifacts. Specify verification-key provisioning, rotation/revocation, expiry,
rollback/freeze handling, parser/size limits, and atomic publication. Compare an
established update-metadata design before inventing a new cryptographic protocol.

Client trust must not depend solely on the mirror's HTTPS certificate or on the
same mutable source delivering its first verification key. Keep offline/local
development workflows explicit; never silently fall back from failed production
verification to unsigned content. Coordinate expiry with R2's time policy.

Finish the existing signed certificate-release path: production key provisioning,
release acquisition, immutable candidate composition, activation through R5, and
consumer drain/reload/restart. Track each TLS consumer's actual enforcement;
using a shared root file does not prove support for XSH's intermediate-key
blocklist. Keep trust policy semantics in [certificate trust](CERTIFICATE-TRUST.md),
not a duplicate specification here.

**Acceptance:** tampered objects/indexes, wrong or revoked keys, stale/replayed
metadata, interrupted publication, and missing clocks fail according to the
explicit policy without damaging the installed generation. Prove key rotation
and recovery. A trust update changes new admissions and performs the documented
cutover for already-running consumers. Missing owner-held keys remain an
external prerequisite; never invent production credentials.

## R5: Activate installed generations and roll back safely

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

For the direct-kernel VM workflow, the launcher may own boot selection, bounded
boot attempts, and fallback while the guest reports its identity and health.
Define this host/guest contract rather than pretending the guest selects a
kernel the host has already supplied. External Internet availability should not
be the sole boot-success condition.

Distinguish operator-authorized rollback to a retained generation from accepting
stale remote metadata. Persist trust/revocation and anti-rollback state outside
ordinary OS rollback, and refuse a fallback that would violate the current
security policy. Define recovery when no retained generation is admissible.
State migrations must be backward-compatible, explicitly reversible, or marked
as preventing automatic rollback; protect user data rather than faking success.

**Acceptance:** install A, stage and boot B, verify the running receipt, and
commit B only after the declared health check. Reject tampered B; recover from
an unbootable B; inject termination at publication/selection/confirmation
boundaries; exercise concurrent requests, full disks, and GC. Every recoverable
case selects a complete admissible bundle with preserved mutable state. Rescue
still works when neither normal generation boots. Linux and Asterinas results
are recorded separately.

## R6: Separate disposable development from long-lived VM policy

Keep current autologin/passwordless-sudo conveniences in an explicitly selected
development profile, not as an implicit policy for unattended reachable VMs.
Define first-boot identity/key provisioning, least-privilege service execution,
secret ownership, and supported remote administration without shared default
credentials. Keep a documented local rescue route.

nftables and Dropbear already exist; the gap is policy and lifecycle integration,
not another firewall or SSH implementation. Apply a tested profile-owned firewall
before exposing listeners, handle failed ruleset updates atomically, and define
Tailscale coexistence without accidentally removing recovery access.

Check the actual VM kernel configuration before claiming sandboxing. The audited
x86_64 fragment disables seccomp and the aarch64 fragment disables namespaces;
these are guest security/OCI capability choices, not hardware enablement. Add
only the capabilities required by selected services or R8, with explicit
failure on unavailable enforcement. Address service resource limits as needed;
never treat ignored fields or a macOS no-op as Linux enforcement.

**Acceptance:** a fresh long-lived VM has no unintended autologin, default
credential, or listener; remote access uses provisioned identity; firewall failure
has a documented safe outcome; selected privilege/isolation limits are verified
inside the guest. The development profile remains convenient and visibly distinct.

## R7: Backups, timers, and persistent diagnostics

**Backups.** Select an established versioned backup tool; `rustic` is a candidate
to qualify, not an already-approved default. The existing `laputa-systems/fs`
copy/sync utility is not a substitute for retained backups. Define encryption-key
recovery, retention, repository checking, application quiescence, and which state
is restored versus reconstructed from package generations. Distinguish restoring
a machine's identity from creating a clone. Prove a manual restore before
scheduling unattended backup or pruning.

**Timers.** Prefer a small supervised XSH scheduler using xinit to own jobs, not
a second init system or a mandatory new subsystem inside PID 1. Specify interval
versus calendar time, overlap policy, missed-run/coalescing behavior, persistence
across reboot, cancellation, bounded retries, and inspectable last/next results.
Handle wall-clock corrections and VM pause explicitly. Do not promise exactly-once
side effects across crashes; use idempotent jobs or explicit reconciliation.

**Diagnostics.** Extend the existing xinit log path rather than replacing it.
Add bounded persistent kernel/boot/service-event capture, boot/generation IDs,
and useful timestamps even before wall-clock synchronization. Document current
copy-truncate loss semantics rather than promising lossless logs. Bound storage,
handle disk-full failure, restrict sensitive data, and provide a redacted support
bundle using existing system-report collectors. No fleet observability platform
or separate per-service logger architecture is required.

**Acceptance:** restore selected mutable state and a bootable system onto a blank
virtual disk from backup plus trusted artifacts, without relying on the original
VM. Test missed/overlapping jobs and clock changes without duplicate uncontrolled
runs. After a forced reboot, diagnostics identify the failed generation and
service history, stay within retention bounds, and exclude secrets.

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

## R10: Close the self-hosting loop

The current xsh package imports seed products, and package-tools retains an
external host-tools base. Treat these as declared bootstrap boundaries, not
proof of a closed build or an in-world XSH rebuild. Keep the compiler in Rust;
this is distribution self-hosting, not language self-implementation.

First qualify a small C/Rust/XSH-build cohort with declared tools, libraries,
sources, environment and writable paths, plus explicit seed exceptions (LAP-28).
No network or ambient host fallback should silently satisfy a missing input.
Poison undeclared inputs and test OS-enforced authority separately from output
reproducibility. LAP-10 owns independent rebuild comparisons; LAP-31 owns the
semantic executor-invalidation contract. Executor provenance alone cannot stop
reuse after an interpreter change alters recipe meaning.

Then build and run replacement xsh/xsht inside a Laputa VM and use them to
rebuild that cohort (LAP-29). Expand only after the bounded loop is useful.
Finally use the in-guest tools and PM to produce a successor bundle and boot it
through the existing launcher (LAP-30). Declare remaining bootstrap trust rather
than claiming complete source bootstrap or a self-hosted world prematurely.

**Acceptance:** one qualified target builds its replacement tools, uses them to
produce the selected successor closure, boots the matching kernel/root bundle,
and verifies the actual running receipt and behavior. No undeclared host tool
supplies a missing capability. Preserve the prior system on failure. Keep local
proof separate from production R4/R5 admission, state migration and fallback;
Linux and Asterinas require their own evidence.

## Delivery gates and evidence

| Gate | Required result |
|---|---|
| G0: Qualified baseline | Record exact source/seed/kernel/profile inputs and runnable existing proofs. Resolve or explicitly report LAP-6's aarch64 verification gap, LAP-7's visual-proof gap, and LAP-21's QMP retry boundary; missing proof is not a pass. |
| G1: Reliable VM | R1-R3 work together with controlled network/time failure, daemon recovery, dirty-disk handling, independent rescue, and enough persistent diagnostics to explain failures. |
| G2: Maintainable VM | R4-R7 deliver authenticated updates, observable activation/fallback, safe VM defaults, and a successful restore onto a blank virtual disk. |
| G3: Optional expansion | R8/R9 are admitted only with a concrete workload, bounded runtime cost, and their own proof; they do not hold G1/G2 hostage. |
| G4: Self-hosted feedback loop | R10 proves a closed cohort, replacement XSH, and successor boot on a named target; it can advance independently of optional expansion and does not waive G1/G2. |

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
a build-only result is not a boot proof. Fix required Asterinas syscalls in the
pinned fork with regression tests, never hide a failure behind a userspace shim
or mark a skipped test as passed. A Linux-first delivery may land while the
Asterinas result remains explicitly unsupported or unverified.

Keep reproducibility and update visibility tied to LAP-10/LAP-11/LAP-12 instead
of creating parallel queues. Stable artifact keys alone do not prove byte-for-byte
rebuilds. When implementation changes a contract, update its owning topic document
and retire the corresponding roadmap gap; leave operational detail out of this
file. Broaden scope only by an explicit owner decision.
