# Qualify Asterinas against Laputa consumers

## Status

- Goal: qualify the pinned x86_64 Asterinas/Firecracker baseline, then deliver
  device coldplug, clock discipline, and IPv4 network compatibility.
- State: A0 in progress. No compatibility slice is accepted.
- Verdict: the paired boot and numeric cases pass. A0 remains open because
  full native-suite accounting is incomplete.
- Survey revision: Laputa `aee5090ea11188dc853ec38297c03ade620f359c`.
- `bash infra/asterinas/qualify.sh baseline --backend both --case boot` passed.
  The `numeric` case passed five tests on each backend with the same PM root.
  The single-VM full run stopped after 30 passed, one failed, and four skipped.
  The failure was `core/tests/test-awk.xsh::test_awk_matrix_arithmetic_and_bit_functions_shard_004`:
  `status was not an exit`. The guest discovered 15,220 cases, while host
  discovery found 15,255. The missing identities and later cases remain open.
- Red boundary: the pinned kernel is three local commits beyond the advertised
  fork branch. GitHub cannot resolve its SHA. Distributed reproduction is blocked.
- Next: finish A0's maintained paired runner, negative result checks, and native
  suite accounting. Fresh public-source reproduction and performance remain open.
- Launch prompt: `Execute docs/CAMPAIGN-ASTERINAS-COMPATIBILITY.md within its local execution boundary; do not push.`

## Charter

Deliver consumer behavior, with Linux as the executable reference. Preserve
Laputa's PM, typed profiles, xinit, XSH, and kernel ownership boundaries.
Fix missing Linux-compatible kernel behavior in `asterinas/`, with kernel tests.
Keep protocol and service policy in existing userspace owners.

Decide and continue within the execution boundary. Record a decision only when
another slice depends on it. A launch authorizes this bounded campaign, not its
successor or publication. Park only the affected item when authority, a forbidden
boundary, or unavailable proof prevents progress.

Use one writer. Kernel dispatch, syscall types, pins, and shared harness files
belong to the coordinator. Apply `orchestrate`'s parent steering checkpoint
after each accepted slice, on resume, and after two failed hypotheses: identify
landed behavior and the limiting factor, then continue, narrow, serialize, or park.
Do not count tooling or documentation as delivered compatibility.

Give a failing slice at most three distinct, evidence-based hypotheses before
parking its branch with the cause, last command, and retry condition. Bisect
after two refuted hypotheses. Never repeat an unchanged failed build. One
coordinator owns shared environment failures. Required behavior stays open when
parked; parking cannot turn a failed capability into an accepted one.

Commit coherent green slices with Conventional Commits and the workstream as
scope. Put the item ID and the reason in the body. Use the contract-change marker
required by AGENTS.md. Run no formatters or CI changes. Push nothing.
Put worktrees and scratch in ignored `.work/`, with `TMPDIR=$PWD/.work/tmp`.
Commit durable decisions in this document. Reuse existing result files rather
than adding another manifest or evidence database.

Fix an encountered breakage in a separate commit only when it prevents this
campaign's acceptance. Bound an execution-loop repair to one cause and one
demonstrated exit test. A warm focused case exceeding five minutes triggers
diagnosis or a smaller reproducer, not a larger timeout or a broad optimization.

## Decisions

| Kind | Binding decision | Reason and reversal condition |
|---|---|---|
| Owner, 2026-11-01 | First qualify the baseline, then deliver device, clock, and network compatibility. Gate the maintained VM afterward. | Owner selected this bounded campaign over the complete maintained-VM program. Only the owner expands that outcome. |
| Owner | Co-develop Laputa and Asterinas. Retain Linux as the reference. | The requested direction. Linux qualification never counts as Asterinas qualification. |
| Prescribed | Keep the present kernel and Rust toolchain pins initially. Do not upgrade to a release by label. | The checkout already contains the 0.19 release notes, while VERSION and the matching dev image retain 0.18.1. Upgrade only for a demonstrated required fix; changing a pinned nightly needs separate owner authority. |
| Prescribed | Prove the local source path independently of public availability. Public reproduction remains red until the exact commit is published. | The lock, gitlink, and local HEAD agree, but remote main lacks three commits. Do not silently repin backward or manufacture a public-closure pass. |
| Prescribed | Use Linux/QEMU and Asterinas/Firecracker with identical packaged XSH binaries, core scripts, and test inputs. Add small direct ABI witnesses for discrepancies. | Separates userspace regressions from kernel failures. Different VMMs remain a confounder; use Asterinas/QEMU only for a discrepancy that needs that control. |
| Prescribed | Start with device coldplug as the first kernel pilot, then clock control, then external IPv4. | A concrete userspace bypass exists. Neither sysfs integration nor frequency discipline is assumed to be a quick syscall patch. |
| Prescribed | Keep ext2 and disposable writable runtime copies. Preserve all installed activation and shared-state formats. | This campaign makes no persistent-storage or production-readiness claim. Ext4, firewall, and maintained activation are successor prerequisites. |
| Prescribed | Use an isolated virtual network with controlled peers. Never expose the experimental guest as an administered server. | This campaign does not implement nftables. No host firewall, route, resolver, clock, or physical-device changes are authorized. |
| Prescribed | Do not require a full native-suite pass before the first consumer fix. Do require complete accounting at baseline and close. | The existing runner is fail-fast. An early failure is not a measurement of every later test. Explicitly exposed unrelated failures remain debt, never skips or passes. |
| Delegated | Choose the smallest internal kernel design satisfying the paired tests and existing safe-Rust architecture. | No syscall success stubs, no silent fallback, no unrelated framework. Reopen a design when its consumer tests disprove its premise. |
| Delegated | Select at most one newer published XSH revision if the current pin lacks the already-maintained DHCP consumer. | Select a coherent binary/core set, rerun A0, and update the pin in one separate change. Do not resume a separate XSH campaign or change language contracts. |

The alternative of immediately porting `qemu-maintained` loses on scope and
checkability: nftables and the ext4 state image are independent unresolved kernel
dependencies. A userspace compatibility layer loses on the kernel ownership
invariant. Retain a close fork with generally applicable kernel fixes, separate
from Laputa configuration. Do not rebase published history or auto-sync upstream
during this campaign. Publication and upstream submission require another grant.

## Baseline

Surveyed on 2026-11-01, Linux x86_64. These are single verification-loop timings,
not performance comparisons. Host tools come from `.out/host/x86_64`.

| Observation or command | Measured result |
|---|---|
| `make asterinas-preflight` | Exit 0, 0.05 s elapsed. Writable KVM and Docker available. Reports missing dev image and Firecracker. Checks declarations, not public source closure or boot. |
| `TMPDIR="$PWD/.work/tmp" PATH="$PWD/.out/host/x86_64:$PATH" bash tests/system/asterinas_host.sh` | Exit 0, 2.70 s elapsed. Archive selection, invalid selections, fake-VMM success/failure, timeout, and child cleanup exercised. |
| `PATH="$PWD/.out/host/x86_64:$PATH" XSH_MODULE_PATH="$PWD" .out/host/x86_64/xsht test --jobs 1 tests/system/asterinas_protocol.xsh` | Exit 0, 4 passed, 0 failed, 0 skipped; 0.34 s elapsed. Uses available host tools, not proof of the locked guest binary. |
| Kernel lock, gitlink, local HEAD | All `5a380196029db437fbbbfe173c7c9cb0d513e122`; clean kernel checkout. |
| `git -C asterinas rev-list --count origin/main..HEAD` and its reverse | 3 local commits, 0 commits on cached origin/main absent locally. `git ls-remote https://github.com/joshuarli/asterinas.git refs/heads/main` independently returns `af0b77c8f11db24ba59b8d2cf29a189281b8e270`. |
| `gh api repos/joshuarli/asterinas/commits/5a380196029db437fbbbfe173c7c9cb0d513e122` | HTTP 422, no commit found. The three local changes are openat2, pathname bytes, and registry configuration. |
| Kernel version declarations | RELEASES.md starts with 0.19.0 dated 2026-10-13; VERSION is 0.18.1; DOCKER_IMAGE_VERSION matches the lock's 0.18.1-20260926. Release notes alone do not identify a released build. |
| XSH pin | `58d321d92963401c3d0113a03e809ca6349c6f16`; resolves through GitHub's commit API and exists in the sibling object database. No same-revision Linux/guest comparison run in this planning session. |
| Runtime resources | Base guest: 2 vCPUs, 1024 MiB. Selected native tests: 2 vCPUs, 4096 MiB. Current polling budgets: 60 s base, 300 s selection, 3000 s full suite. |
| Local Asterinas artifacts | No `.out/asterinas-firecracker` directory and no cached `asterinas/dev:0.18.1-20260926` image. No kernel build or guest boot attempted. Cold-build and warm guest-loop times are unmeasured. |

Known source gaps are not measured guest failures. Boot setup explicitly bypasses
mdev coldplug. The x86 syscall dispatch lacks clock-control entries 159, 227,
and 305, consistent with the pinned ABI book. Netlink socket creation accepts
ROUTE and KOBJECT_UEVENT and rejects other standard families, including NETFILTER.
Ext2 inode sync reaches block-device flush and propagates failure, which does not
establish crash durability. The Firecracker configuration attaches one writable
root disk and no network device. Its TCP check is loopback only.

### Foundation proof

The plan relies on two narrow facts: source/test selection stays tied to its
archive, and a nominal success cannot hide incomplete guest execution or leave
the owned VMM child alive. The real staging and VM-runner scripts passed their
host fixture suite. The real protocol validator passed all four tests, including
missing-marker rejection and its failing CLI path. This reaches blast-radius
rung 4, executed code, for the qualification plumbing.

Matched binaries, actual kernel behavior, coldplug delivery, and external
networking remain unproven. A0 and A1 establish those foundations before expanding
the harness. Preflight does not claim a guest result from fake-VMM tests.

## Sequence

Commands beginning `bash infra/asterinas/qualify.sh` below describe a **new**
entry point built incrementally by the owning slice. They do not exist at this
revision. Its required interface is a cohort (`baseline`, `device`, `clock-abi`,
`clock`, `network-state`, `network`, `all`, `resources`, or `published-inputs`),
`--backend linux|asterinas|both`, and optional `--case NAME` for one named case.
Unknown cases, zero discovered cases, absent results, unavailable required
facilities, and backend mismatches return nonzero. The wrapper delegates to
existing builders and runners. It does not become a second PM or VMM framework.
Add each cohort only with its consumer delivery.

Each item is one capability, with its local proof on the integrated tree.
Cold builds are setup, not an excuse to rebuild every case. Announce expensive
fetch/build and full-suite runs before starting them. Measure their loop costs
in A0. Keep warm single-case commands within five minutes; the grouped clock
and final-suite milestones may take longer and must declare their bounds.

| Item, size | Prerequisites and owned files | Delivery and local acceptance |
|---|---|---|
| A0 baseline pilot, M | None. Coordinator: `infra/asterinas/qualify.sh` (new), existing setup/viability/staging scripts as needed, `system/qemu.xsh`, focused host tests, `docs/ASTERINAS.md`, lock/gitlink only if required. | Run `make asterinas-fetch`, `make asterinas-build`, then `bash infra/asterinas/qualify.sh baseline --backend both`. Boot the same PM-produced XSH/core/test payload on Linux and Asterinas. Run the existing boot behavior and one nonempty native numeric selection. Prove matching artifacts, zero failed selected cases, and rejection of a missing result. Measure cold setup and warm rerun separately. Preserve current public-pin failure. |
| A1 device pilot, M | A0. Kernel owner: sysfs/device registration, existing kobject uevent integration, corresponding kernel regression. Consumer owner: `guest/asterinas/common/boot-setup.xsh`, PM composition, mdev package selection, device fixture and cohort. Coordinator serializes shared harness changes. | `bash infra/asterinas/qualify.sh device --backend both`. Deliver real coldplug to packaged mdevd with a device-number-bearing virtio disk and normal rules. Verify metadata, synthetic add delivery, correct node numbers and permissions, bounded completion, daemon restart, and repeat coldplug. Remove the explicit Asterinas coldplug bypass only after this passes. Preserve the required static single-threaded initramfs handoff. |
| A2 clock ABI, M | A1 pilot accepted. Kernel owner: clock implementation, x86 dispatch, capability checks, direct ABI regression and its matching Linux run. Clock fixture/cohort. | `bash infra/asterinas/qualify.sh clock-abi --backend both`. Provide real clock_settime, adjtimex, and clock_adjtime semantics required by the packaged daemon. Test readback, positive/negative offset and frequency, units, unsupported modes, invalid clock IDs, and unprivileged rejection. No clock control touches the host. |
| A3 disciplined clock consumer, M | A2. Kernel time/timer owners and kernel regressions as failures demand; `ntpd-rs/clock-steering/src/unix.rs` is the contract, not a place to add Asterinas fallback. `tests/integration/fixtures/ntp-*`, package overlay and clock cohort. | `bash infra/asterinas/qualify.sh clock --backend both --case startup-behind`, then the whole `clock` cohort at its milestone. Run packaged ntpd-rs under xinit, UID/GID 123 with only CAP_SYS_TIME. Prove both startup directions, frequency steering, restart restoration, no-peer behavior, and pause/resume against an independent running peer. Firecracker API ownership and its pause/resume control belong to this slice. See Acceptance. |
| A4 IPv4 state operations, M | A1. Kernel netlink route/link/address owners and regressions; qualification-only network fixtures and cohort. | `bash infra/asterinas/qualify.sh network-state --backend both`. Attach one virtio-net device to a disposable isolated network. Run actual XSH dumps and mutations, ACK/error, multipart completion, route/address deletion and re-observation. Preserve a deliberately foreign address/route. Reject stale preconditions. |
| A5 DHCP and connection recovery, M | A4 and A2, then serialize with A3 when shared files overlap. Kernel network/socket owners and regressions; existing DHCP/syslog consumers, network fixtures/cohort. | `bash infra/asterinas/qualify.sh network --backend both --case lease-acquire`, then the complete `network` cohort at its milestone. Prove controlled DHCP acquire, renew/rebind, NAK/expiry cleanup, changed DNS/routes, daemon restart, carrier loss and return, plus TCP recovery. No second network manager. |
| A6 integrate and harden, M | A1–A5. Coordinator owns shared runner, pins, topic docs, campaign status, and removal of obsolete bypass code. | `bash infra/asterinas/qualify.sh all --backend both`. Run all required cases serially with no new skips or failures. Repeat the complete native XSH accounting from A0. Verify cleanup on cancellation and bad guest output, and unchanged normal Linux profile behavior for any shared QEMU changes. Run independent completion review under `ultrareview`; resolve its supported P1/P2 findings before acceptance. |
| A7 account for resources and close, S | A6. Coordinator: existing runtime result output and topic docs only. | `bash infra/asterinas/qualify.sh resources --backend both`. Record actual kernel/initramfs/root sizes, peak VMM RSS, configured memory, warm test CPU time, and any deferred time gates. No optimization before compatibility. Close with required cases green, remaining native-suite debt explicit, and successor blockers preserved. |

A0 must deliver one real end-to-end pilot before new harness cohorts. A1 must
deliver the first actual kernel/userspace improvement before wider test tooling.
Do not add generators, generalized fuzz runners, or a blanket syscall inventory
as an entry fee. Test an exposing behavior before implementing its fix.

Each kernel behavior fix includes a regression in the fork's existing
`test/initramfs/src/regression` tree. Its cohort builds and runs that same
witness against Linux and Asterinas, then runs the packaged consumer. A witness
that only compiles is not coverage. Reuse kernel-mode tests for internal
invariants when appropriate; do not substitute a workspace-wide `make check`,
which includes formatting, for the focused guest proof.

Default execution is serial. After A1, A2/A3 kernel-clock work and A4 kernel-route
work may prepare in parallel only in disjoint kernel files and distinct fixture
files. The coordinator alone edits `qualify.sh`, dispatch, lockfiles, gitlinks,
package composition, and shared runner configuration. Any overlap serializes
the slices. Integrate and run KVM acceptance one lane at a time. Additional
delegation follows `orchestrate` only when it improves accepted delivery.

## Acceptance

Use the A0 Linux image as the executable reference, not a historical green log.
Keep the same XSH executable, core scripts, PM generation inputs, ABI witness,
corpus, vCPU count, and memory allocation on both sides. Differences in kernel
and VMM are intentional. Normalize only generated PIDs, interface indices,
assigned addresses from declared fixtures, and actual timing jitter. Never
normalize errno, missing events, capability sets, state transitions, or lost data.
Keep the behavior-to-test mapping here and in the tests, without another register.

| Deliverable | Runnable proof | Required threshold and failure evidence |
|---|---|---|
| D1 matched usable baseline | `bash infra/asterinas/qualify.sh baseline --backend both` | Both boot proofs and a nonempty identical numeric selection pass. Byte-identical packaged XSH/core and corpus. A missing marker or intentionally wrong expected value fails. Local source closure is distinct from remote publication. |
| D2 device compatibility | `bash infra/asterinas/qualify.sh device --backend both` | Every fixture device has Linux-compatible major/minor, DEVPATH and SUBSYSTEM data. A synthetic add reaches mdevd and creates the expected disposable node. Three repeated coldplugs and one daemon restart complete within 60 s each, with correct ownership/mode and no duplicate processing after completion. A deliberately missing event fails. Test re-enumeration only where the VMM supports it; do not require unsupported Firecracker hotplug. |
| D3 clock ABI and real discipline | `bash infra/asterinas/qualify.sh clock --backend both` | A2 ABI corpus passes. Startup at ±10 s reaches absolute error below 100 ms for five consecutive one-second samples within 120 s. A controlled 100 ppm source produces correction with the Linux-observed sign and within 20 ppm of the source, restored within 1 ppm across daemon restart before any peer is available, within a 300 s case budget. Privilege removal fails clock mutation. No-peer readiness remains distinguishable from synchronization. |
| D3 pause and clock consumers | `bash infra/asterinas/qualify.sh clock --backend both --case pause` | Pause for 5 s while the peer continues outside the guest. After resume, recover below 100 ms for five samples within 120 s. Test intentional rejection under the unchanged daemon step policy separately; an abort cannot pass the recovery case. Observe monotonic/boottime behavior separately from realtime. Wall steps must not expire xinit readiness, restart, or shutdown deadlines prematurely. A peer inside the paused guest cannot prove this case. |
| D4 IPv4 state parity | `bash infra/asterinas/qualify.sh network-state --backend both` | Every named route/link/address case matches Linux output/error/side effects. A malformed or failed request cannot masquerade as an ACK or partial successful dump. Lost-notification recovery re-observes state and preserves foreign resources. Reversing an expected ACK/error fails the gate. |
| D5 maintained network consumers | `bash infra/asterinas/qualify.sh network --backend both` | With a controlled 20 s lease, prove acquire, renewal, rebind, NAK and expiry. Every intended transition completes within 60 s. Resolver, owned address and route state match the fixture after each transition; expired owned state disappears and foreign state survives. Three carrier cycles and one DHCP restart recover with no duplicate owner. Transfer and verify a deterministic 1 MiB TCP payload before and after disruption. A disconnected socket either completes correctly or fails explicitly and a new connection succeeds. |
| D6 integrated bounded target | `bash infra/asterinas/qualify.sh all --backend both` | D1–D5 pass with zero required cases failed, skipped, unknown or unexecuted. Repeat device/network recovery ten times with fixed inputs. Cancellation leaves zero owned VMM/server processes and zero owned TAP devices. Existing Linux consumers of changed shared launch code still pass. |
| D7 honest cost account | `bash infra/asterinas/qualify.sh resources --backend both` | Nonzero binary sizes and peak RSS come from the actual passing artifacts/processes. No dependency is added without build-time and binary-size impact. No guest-memory increase beyond 4 GiB and no full-runner deadline increase without a measured cause and a smaller regression. Product speed is not a release claim for this campaign. |

The thresholds above are prescribed engineering targets, not measured Asterinas
performance. Retain stricter existing consumer assertions where present.
For clock convergence, first establish that the controlled Linux reference meets
the target. A failure on both sides belongs to the fixture or existing userspace
owner; it is not license to weaken the Asterinas gate.

At A0 and A6, run `XSH_TEST=all make asterinas-test` and the same locked corpus
on Linux. The current Asterinas run is fail-fast. Count passed, failed, skipped,
and unexecuted cases explicitly. Run remaining modules separately through
`XSH_TEST=PATH` to expose failures hidden behind the first one. Bound each run
with the existing 3000 s full-suite and 300 s module budgets. If a module itself
stops early, its remaining cases are unexecuted, not a pass. Preserve the exact
case identities and causes in the existing qualification results. A6 permits no
new failure or disappearance against A0. Required D1–D6 cases cannot be excluded
as baseline debt. Limit additional module fan-out to two hours per milestone.
Discover case identities before execution and explicitly retain every remaining
case as unexecuted when that budget expires. This campaign does not promise
full native-suite compatibility.

Check the evaluator with a real improvement, a deliberately regressed expected
result, an unrelated baseline failure, and an unchanged Linux consumer. The
first must go red-to-green, the second must fail, the third must remain visibly
debt, and the fourth must remain green. Do not commit deliberate regressions.

Resource measurements follow AGENTS.md. Time-based gates run only between
successful `perf-gate-ready` and `perf-gate-ready -1` checks. Discard overlapping
load, report `perf gate deferred: host busy`, and leave performance qualification
open. Measure size and memory even when time gates are deferred. A7 records
costs, not a speedup. Any later optimization requires five interleaved baseline
and candidate runs, medians and spread, completed-work checks, and its own scope.

## Needs environment

- **Fresh public-source reproduction:** the owner must publish the three local
  kernel commits through their chosen branch policy. The executor must not push.
  Then run `bash infra/asterinas/qualify.sh published-inputs --backend asterinas`.
  It must fetch the exact kernel and XSH pins into fresh caches under `.work/tmp`
  and compare them with the lock/gitlink. HTTP availability alone is insufficient.
  Until then, local qualification may finish; public reproducibility stays red.
- **Cold inputs:** this host has KVM and Docker but lacks the pinned dev image
  and Firecracker. `make asterinas-fetch` followed by `make asterinas-build`
  is the first execution setup. Registry/network failures get one shared owner;
  unavailable downloads park guest proofs rather than inventing a pass.
- **Isolated virtio network:** A4 needs `/dev/net/tun` and an owned TAP inside a
  disposable container network namespace with NET_ADMIN and writable KVM.
  Run `bash infra/asterinas/qualify.sh network-state --backend both` there.
  If that facility is unavailable, report network qualification unverified.
  Do not fall back to altering the host network.
- **Quiet host:** only final time gates need quiet capacity. Deferred measurements
  block performance completion and release claims, not compatibility iteration.

These entries do not hold local close open when the needed environment is absent.
Report each excluded proof and leave its associated capability unqualified.
Neither a parked required case nor an unavailable environment permits claiming
the corresponding D1–D6 deliverable passed. Report partial completion when a
required performance gate is deferred; do not call the campaign done or release.

## Execution boundary and non-goals

Planning authorizes only this document and its verification. A separate launch
authorizes local Laputa changes and local kernel commits in the initialized
`asterinas/` checkout, with lock/gitlink updates committed together. Read the
kernel and component AGENTS.md files and `../xsh/AGENTS.md` before their relevant
edits. Never reset dirty sibling work or shared caches to force a clean build.

Execution may download declared inputs, use existing Docker builders, run local
KVM guests, create disposable disk images, and create an isolated test network
inside an owned container. It may change clocks and credentials only inside
those guests. Keep control endpoints local and use fixture data and keys.
Use kache for Rust and mold for Linux musl. Add no dependency by default.
An indispensable dependency must satisfy license/maintenance review and report
transitive weight, build CPU time and binary-size impact before acceptance.

Forbidden effects: push, release, upstream PR or issue submission, deployment,
public service exposure, deletion of unrelated worktrees/data, host clock or
network mutation, nightly upgrades, and production-state migration. Missing
authority parks only that effect. No roadmap entry authorizes successor work.

Contract changes in scope are Linux-compatible device sysfs/uevent behavior,
the clock-control ABI with CAP_SYS_TIME enforcement, and the IPv4 netlink/socket
semantics consumed by existing XSH. Surface their exact input/error/side-effect
changes in each commit and update kernel tests and topic docs together. Preserve
PM public APIs, xinit schema, activation records, trust policy, and state formats.
The qualification wrapper is an internal developer command, not a shipped applet.

Do not implement nftables, ext4 journaling/repair, persistent activation on
Asterinas, Dropbear/doas multiuser qualification, TUN/Tailscale, perf/BPF,
io_uring, OCI/cgroups, DRM/Wayland, or physical hardware in this campaign.
Do not remove Linux or its graphical proof. Do not enable ntpd-rs in normal
profiles merely because the isolated clock fixture passes. No release or
production-readiness claim follows from this bounded result.

The successor must preserve the existing maintained-VM contract: first-boot
identity; authenticated SSH; firewall before SSH with failure denying startup;
DHCP, disciplined time and persistent diagnostics; service/network recovery;
generation update, reboot, failed-candidate rollback and restore. Its entry gate
is D1–D6 plus a separate plan resolving nftables compatibility, the ext4 state
image, filesystem crash/recovery semantics and credential enforcement. Ext2 API
success, a VMM kill, and host-side activation receipts cannot substitute for
guest filesystem durability or host-storage power-loss proof. Tailscale remains
a separate optional dependency until its policy is selected. External NTS
interoperability and a long-lived soak also belong to that successor. Reproduce
any relevant upstream permission report with a bounded conformance test before
treating it as a defect of this pin. Do not turn issue titles into qualification.

## Reference

Verified code map at the survey revision. Labels describe this campaign's work.

| Role | Owning source | Use |
|---|---|---|
| Reuse | `infra/asterinas/inputs.lock:2`, `infra/asterinas/preflight.sh:33`, `infra/asterinas/setup.sh:113` | Pinned local source, gitlink and toolchain checks. Keep the developer local-source path. |
| Reuse | `infra/asterinas/prepare-xsh.sh:23`, `infra/asterinas/stage-xsh-test.sh:69` | Immutable selected XSH archive and corpus staging. |
| Change | `infra/asterinas/viability.sh:151`, `infra/asterinas/viability.sh:266`, `infra/asterinas/viability.sh:284` | Existing PM package roots, Firecracker config, writable runtime copy. Extend only for the current consumer. |
| Reuse/change | `infra/asterinas/run-test-vm.sh:72`, `infra/asterinas/guest_protocol.xsh:1`, `tests/system/asterinas_host.sh:280` | Failure-aware VM lifecycle and host-side result rejection. |
| Change | `guest/asterinas/common/boot-setup.xsh:43`, `mdevd-rs/src/bin/mdevd-coldplug.rs:1` | Exposing bypass and actual coldplug consumer. Remove the bypass only with kernel delivery. |
| Change | `asterinas/kernel/core/src/fs/fs_impls/sysfs/mod.rs:20`, `asterinas/kernel/core/src/net/socket/netlink/kobject_uevent/mod.rs:1` | Device publication and existing uevent transport. Source presence is not device delivery proof. |
| Change | `asterinas/kernel/core/src/syscall/arch/x86.rs:409`, `ntpd-rs/clock-steering/src/unix.rs:287` | Missing clock-control dispatch and real consumer modes. |
| Reuse/change | `tests/integration/ntp-clock-guest.sh:1`, `tests/integration/fixtures/ntp-clock-guest.xsh:1`, `tests/integration/fixtures/ntp-frequency-guest.xsh:1` | Existing Linux clock oracles and assertions. Their ext4/profile assumptions need an explicit disposable ext2 fixture adapter, not weaker assertions. |
| Change | `asterinas/kernel/core/src/syscall/socket.rs:68`, `asterinas/kernel/core/src/net/socket/netlink/route/kernel/mod.rs:1` | Actual supported netlink families and route implementation. |
| Reuse/change | `system/qemu.xsh:103`, `system/qemu.xsh:480` | Sole owner of host QEMU launch. Its normal path assumes GPT/ext4; add only the narrow initramfs/ext2 qualification path A0 requires. |
| Successor | `profiles/qemu-maintained.xsh:5`, `tests/integration/maintained_guest.py:46`, `asterinas/kernel/core/src/fs/fs_impls/ext2/impl_for_vfs/inode.rs:341` | Existing maintained services, separate ext4 state disk, and ext2 flush boundary. Preserve these distinctions. |

Read [Asterinas](ASTERINAS.md), [testing](TESTING.md),
[QEMU](QEMU.md#maintained-vm-activation), and the [roadmap](ROADMAP.md) for the
owning contracts. The prior [graphical campaign](CAMPAIGN-TINYLAND-GHOSTTY.md)
ties acceptance to guest behavior. Reuse that evidence standard without copying
its release authority, completed results, or append-only history. There is no
tracked DECISIONS.md in this checkout.
