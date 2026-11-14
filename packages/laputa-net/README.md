# Network plan reference (IPv4 and IPv6)

`network_plan.xsh` provides an offline, read-only plan for one existing `veth`
or `dummy` virtual Ethernet interface and one address family, IPv4 or IPv6. The
package's installed `ifup` service continues to own boot setup. The planner and
the controller are source-tree development tools; nothing here is wired into
boot, and the packaged `ipv6.conf` keeps IPv6 disabled (see
[IPv6 cohort](#ipv6-cohort)).

```sh
XSH_MODULE_PATH="$PWD" xsh packages/laputa-net/network_plan.xsh \
  tests/system/fixtures/network-policy-conflict.json
```

The command prints a JSON object containing the interface identity, observation
sequence, and ordered operations. The fixture requests adding `192.0.2.3/24`
and removing the owned `192.0.2.2/24`. Foreign resources remain outside the plan.
The output contains no lease contents, raw network attributes, or credentials.

## Input contract

`NetworkPlanInput` contains `intent`, `owned`, and `observed`.
`network_decode_input` decodes the JSON and validates it exactly with
`require_exact`: unknown fields at any depth, duplicate keys, missing fields,
`null` for a required field, integers beyond i64, and values of the wrong type
fail with the field path before any planning. Nothing is coerced, so `"24"` and
`24.5` are not a prefix. A document with the same fields from YAML or TOML
validates to an equal value, and a lexical INI or CSV record reaches the schema
only through `codec.decode_as`. Malformed JSON and inputs larger than 65536
bytes fail. Input files are trusted observations supplied by the caller. The
command never falls back to the host.

The planner and capture replay share `network_read_input`. It resolves the
selected path, opens its parent as an `FsRoot`, and reads at most 65537 bytes.
Truncated input fails before UTF-8 decoding. Exactly 65536 valid bytes remain
admissible. `network_input_limit` owns that limit. Rooted read failures retain
the selected path, observation state, errno, and stable error kind in the
`NetworkReadFailed` variant. Resolution and root-opening errors propagate directly.

`NetworkIntent` selects the interface by both index and name. It requests one
canonical address, a gateway of the same family, and a nonnegative default-route
metric. The address text selects the family: any colon selects IPv6. An IPv4
address has a prefix from 1 through 32. An IPv6 address has a prefix from 1
through 128 and must be a global unicast address in the exact RFC 5952 text the
kernel reports (lowercase, no leading zeros, the first longest zero run
compressed, never a single group). Unspecified, loopback, link-local, multicast,
IPv4-mapped and IPv4-compatible addresses are refused as intent addresses. An
IPv6 gateway may also be link-local. A family mismatch between address and
gateway is invalid. A dual-stack link is two intents, one per family, applied
one after the other.

`NetworkOwnership` grants authority over exact addresses and routes on that
interface. Observation does not grant ownership. A desired resource already
present without explicit ownership produces a conflict.

`NetworkSnapshot` describes the complete selected cohort of the intent's
family. Addresses identify local address and prefix. Routes describe main-table
unicast default routes on the selected interface, with a gateway and metric.
Other route tables, source routes, multipath routes, the other address family,
and physical interfaces have no representation in this cohort. A snapshot or
ownership list that holds a resource of the other family is invalid, so an IPv4
plan never retires an IPv6 resource or the reverse. A host adapter must reject
unsupported or incomplete observations rather than discard information needed
to recognize a conflict.

Each observed or owned list accepts at most 64 resources. Invalid addresses,
duplicate resources, and another default route using the desired metric fail.
An IPv6 intent whose local address is already present with another prefix fails,
because the kernel refuses a second prefix for the same local address.
The caller increments `sequence` for each complete observation. The sequence is
an observation ordinal, not a kernel generation or atomic snapshot guarantee.

## Plan and replay contract

`network_plan` is pure. It brings the selected link up when needed, adds missing
desired resources, and removes only explicitly owned retired resources. Equal
desired and observed state produces zero operations. No operation flushes an
interface or replaces a foreign route.

`network_replay` validates the plan and consumes at most 133 typed events.
The first event must contain
the plan's exact precondition snapshot. Successful operation results follow the
plan's zero-based operation order. A fresh final observation must corroborate
the desired state, removal of retired owned resources, and survival of foreign
resources. Acknowledgements alone do not establish convergence.

Stale preconditions, denied operations, and lost events return a reason requiring
full re-observation. Missing, reordered, repeated, or truncated observations
return an invalid replay result. Partial application does not imply rollback.
The result never authorizes retrying a mutation against a stale snapshot.

## Typed projection and changes

`network_kernel.xsh` plans over XSH's `lib.net_state`; it holds no raw dump
checks or request bytes. The boot service and installed package payload remain
unchanged.

`network_change` validates the complete plan, then maps one operation onto a
`net_state.Change`. `net_state.request` encodes it. An address request carries
the interface index, local address, and prefix; a default-route request is a
main-table (254), boot-protocol (3), universe-scope, unicast route carrying the
gateway, interface index, and metric with the table attribute. Removals send the
same protocol and type, so they delete exactly the route this controller adds
and never a route of another protocol. Additions use exclusive creation.
Encoding bytes does not qualify their execution against an observed host. See
[reconciliation](#reconciliation) for the preconditions `network_changes`
enforces before any effect.

`network_outcome` maps a kernel `Refused` verdict to `NetworkDenied` and any
other failure to `NetworkFailed`; `network_lost_events` maps a drained `Lost`
notice to `NetworkLostEvents`.

`network_project_dump` requires `net_state.project` to accept the dump: an
incomplete, interrupted, truncated or undecodable socket, link, address or route
dump is an error, never an empty state. `network_project_state` then requires the
selected independent virtual Ethernet interface and projects only the intent's
family; the other family's objects, even unsupported ones, neither enter nor
block the projection. It rejects selected secondary
IPv4 addresses, point-to-point addresses, and unsupported selected default
routes, and applies the IPv6 rules below. An empty projected route list therefore follows observed absence, never
a fallback.

`network_project_state` projects a selected default route only when it is an
ordinary-traffic (`tos` 0) main-table unicast route with boot protocol, universe
scope, one gateway out of the managed link, no source or preferred-source
selector, and no attribute `net_state.Route` does not model
(`other_attributes` empty). A TOS-specific default on the selected link is
refused as `selected default route is TOS-specific and cannot converge with
ordinary traffic`, even beside an ordinary default; other unsupported shapes are
refused as outside the supported cohort or as carrying unsupported attributes.
Defaults on other interfaces are not projected. The four dumps behind one
observation are still taken one after another with no shared kernel generation.
`network_project_stable_states` projects two consecutive observations only when
they are identical and otherwise reports that the observation changed. This
narrows cross-dump skew but cannot rule out a change that reverts between the
two observations.

The projection checks all IPv4 preferred-source dependencies on selected
addresses, including routes through another interface. Its address-derived
exception requires zero flags, no source selector, boot-time kernel protocol,
one hop with no gateway out of the managed link, priority 0, and no unmodeled
attributes. Connected, local, and broadcast destinations must also match the
address's exact derived shape. This exception does not grant mutation authority.

## IPv6 cohort

IPv6 uses the same `State` and `Change` records, the same plan, and the same
reconcile pass as IPv4. These kernel specifics shape the cohort, and each is
measured on Linux 7.2.9 in a private network namespace.

- **Metric.** An IPv6 default added without a priority is stored with metric
  1024, never 0. An intent metric of 0 therefore means 1024:
  `network_desired_route` is the single source for it, and the plan, the
  requests and `network_replay` all carry 1024, so the route is created and
  removed with an explicit nonzero priority. The zero-metric removal hazard
  below still refuses any observed or owned route with metric 0.
- **Link-local addresses.** The kernel creates `fe80::/64` addresses on link up
  and removes them with the stack. They are foreign state outside the cohort,
  never a plan operand, and they survive every plan. An intent address in
  `fe80::/10` is invalid.
- **Lifetime-managed addresses.** An address without `IFA_F_PERMANENT` (SLAAC,
  temporary) appears and expires without a request. It is foreign state outside
  the cohort. A permanent address that is point-to-point, scoped other than
  global, or flagged `HOMEADDRESS`, `MANAGETEMPADDR`, `NOPREFIXROUTE`,
  `MCAUTOJOIN` or `SECONDARY`, is refused with an explicit conflict.
- **Duplicate address detection.** A new static address is observed with
  `IFA_F_TENTATIVE` set until detection completes, and the cohort treats it as
  present: acknowledgement and a fresh observation establish that the kernel
  holds the configuration, not that the address is usable. A selected address
  with `IFA_F_DADFAILED` fails the projection with `selected IPv6 address failed
  duplicate address detection`, so a duplicate is an explicit failure on the
  next observation and never a silent success. A pass that adds an address
  returns before detection finishes. `network_project_stable_states` therefore
  reports an observation as changed while the flags settle.
- **Router advertisements.** A default route with protocol `RTPROT_RA` (9) is
  kernel-managed foreign state: it comes and goes with the advertised lifetime.
  The projection leaves it out of the cohort, so no plan removes or counts it.
  The cohort cannot see its metric, so a desired default at the same metric is
  refused by the kernel (`EEXIST`) as a denied operation with re-observation,
  and the advertised route survives. Any other protocol on a selected default
  (for example static, 4) still fails the projection as outside the supported
  cohort, as for IPv4.
- **Route attributes.** Every IPv6 route dump carries `RTA_CACHEINFO` (12) and
  `RTA_PREF` (20). They are the only unmodeled attributes accepted on an IPv6
  selected default; metrics, encapsulation and any other attribute are refused as
  `selected default route carries unsupported attributes`. `net_state.Route`
  reports only the attribute kinds, so the router preference value itself is not
  visible. Route identity in the kernel's lookup ignores it.
- **Preferred source.** The kernel does not give address-derived IPv6 routes a
  preferred source, so any route (on any interface) whose preferred source is a
  selected IPv6 address is a foreign dependency and refuses the projection.
- **No primary and secondary addresses.** The IPv4 same-prefix promotion rule
  does not apply to IPv6.
- **Disabled stack.** `ipv6.conf` packages `disable_ipv6 = 1`, `accept_ra = 0`
  and `autoconf = 0` for `all` and `default`; `interfaces` configures only
  loopback. The kernel refuses an address on a link with the stack disabled. The
  controller reports that as `NetworkDenied` with a re-observation request and
  mutates nothing; it neither detects nor changes the sysctl. A test reads the
  packaged files so the policy these rules assume cannot drift unnoticed. The
  maintained profile's status service relies on the same file to report IPv6 as
  unsupported, so enabling IPv6 for a managed link needs an explicit override of
  that drop-in, not a change to the controller.

Default routes through a link-local gateway need no address. A default through a
global gateway needs the gateway on-link, which the kernel derives from the
address's prefix route. Neither the on-link rule nor reachability is checked by
the controller; a gateway the kernel refuses is reported as a denial.

## Reconciliation

`network_reconcile` runs observe -> pure plan -> apply with preconditions ->
re-observe over one `net_state` notification stream. It subscribes before the
first observation, so a change after that observation is visible either in a
lost notification or in the next complete observation.

`network_apply_plan` refuses the whole change set before any effect unless the
plan is exactly what `network_plan` computes, every IPv4 same-prefix address
addition is unambiguous, and every change is exactly encodable. It then applies
the changes in plan order through `net_state.apply`. Before each change it
re-observes and requires the plan's predicted cohort for that step; after each
change it drains notifications and re-observes again. A mismatch before a change
reports `observation changed before operation N`; an acknowledged change whose
re-observation diverges reports that divergence. In both cases the pass stops
with `NetworkReobserve` and no further change is attempted. A refused operation
is recorded as `NetworkDenied`, the resulting state is observed, and
`network_replay` turns it into a re-observation; a transport failure or an
untrustworthy observation is likewise a re-observation. Nothing is retried
against a stale snapshot, and nothing is rolled back.

`network_reconcile` returns a `NetworkReconcile` holding the plan, the number of
changes attempted, the last trusted observation, the ordered replay events, and
the verdict. A plan with no operations attempts no mutation and still
re-observes. Foreign addresses and routes are never in an operation; the final
observation is checked by `network_replay`, so a vanished foreign resource is
reported rather than silently accepted.

Two deletion hazards found by independent review are closed before any request
is built. A zero-metric default route cannot be removed exactly: Linux treats
`RTA_PRIORITY` 0, present or absent, as "unset", so a deletion naming metric 0
deletes a route of any metric with the same remaining key. Measured on Linux
7.2.9 in an unprivileged network namespace: with only a metric-300 default
present, a `RTM_DELROUTE` naming metric 0 returned errno 0 and removed it, with
an explicit `RTA_PRIORITY` attribute carrying 0 and with that attribute omitted.
The controller therefore never creates and never removes a zero-metric default
(`a zero-metric default route is never created ...` /
`... cannot be removed exactly ...`), and an operator's metric-0 route survives.
Linearizing the metric is not a substitute: creation is exclusive, so a failed
removal after a successful addition would leave both. A route carrying an
attribute `net_state.Route` does not model cannot be deleted exactly, because
the encoder would omit that attribute while the kernel still matched the rest of
the key. `network_project_state` refuses such a selected default as
`selected default route carries unsupported attributes`, `net_state.request`
independently refuses to add one, and `network_changes` refuses the whole plan.
`net_state.request` permits a removal of a route with unmodeled attributes,
because a removal sends only the modeled key; the projection is therefore the
gate that keeps such a route out of every change. Both are measured: a default
created with an `RTA_METRICS` (kind 8) MTU is observed with
`other_attributes == [8]` and refused, while an ordinary default projects and is
unaffected.
`net_state.Route` now carries the typed `tos`, so a TOS-specific selected
default is refused rather than projected as an ordinary one.

## Verification boundary

```sh
XSH_MODULE_PATH="$PWD:$XSH_ROOT/core" xsht check packages/laputa-net/network_plan.xsh \
  tests/system/network_policy.xsh
XSH_MODULE_PATH="$PWD:$XSH_ROOT/core" xsht test tests/system/network_policy.xsh
XSH_MODULE_PATH="$PWD:$XSH_ROOT/core" xsht test tests/system/network_policy_kernel.xsh
XSH_MODULE_PATH="$PWD:$XSH_ROOT/core" xsht test tests/system/network_policy_input.xsh
XSH_MODULE_PATH="$PWD:$XSH_ROOT/core" XSH_ROOT="$XSH_ROOT" XSH_HOST="$XSH" \
  xsht test tests/system/network_policy_applier.xsh
XSH_MODULE_PATH="$PWD:$XSH_ROOT/core" xsht test tests/system/network_policy_schema.xsh
bash tests/system/network_policy_docker.sh /absolute/path/to/xsh-tools
```

`network_policy_applier.xsh` runs `tests/system/fixtures/network-policy-applier.xsh`
through `linux.run_in_namespaces` with a private user and network namespace. That
is the cheapest disposable environment that performs real kernel mutations: the
process owns the namespace, so both veth endpoints and every address and route it
creates disappear with it, and no host or guest network state is touched. The
same fixture runs the IPv4 cases and then the IPv6 cases against one veth pair,
so each family is also checked to leave the other's state alone. It
requires unprivileged user namespaces; the test skips when the kernel or the
container refuses them, and the fixture itself refuses to run outside its
`disposable-namespace` scope. The live IPv4 guest qualification below executes
this same witness inside a disposable `qemu-self-hosting` KVM guest.

The Docker command expects `bin/xsh` and `core/` under the supplied tool root
and the existing `xsh-test` image. The container runs as the caller's UID and
GID with all capabilities dropped, a read-only root, and read-only bind mounts.
The command creates disposable capture files under `.work/tmp` and removes them
on exit. It never joins the host network namespace or pulls a missing image.

`network-policy-conflict.json` is synthetic. It reduces an address change followed
by a denied removal and retains an unrelated operator address and default route.
The native tests retain stale, missing, reordered, truncated, and denied-result
cases without network effects.

`network-policy-docker-conflict.json` is a 728-byte capture from an ordinary Linux
Docker network namespace. The capture records `eth0`, index 2, its existing
`172.17.0.2/16` address, and its default route through `172.17.0.1` with metric 0.
The intent matches those existing resources, and explicit ownership is empty.
The real policy failure is `desired address is foreign; ownership cannot be inferred`.
This is an ownership admission failure, not a captured kernel mutation failure.
The error concerns the foreign address. The captured default-route fields omit
TOS and predate the typed `tos` field; they do not establish route identity or convergence.

`network-policy-capture.xsh` obtains a complete typed `linux.network_dump` and
rejects field issues, ambiguous addresses, and unsupported default routes.
The driver accepts exactly one veth, one selected IPv4 address, and one selected
IPv4 default route. Linux's absent route-priority attribute denotes metric 0.
The driver records only the selected policy fields and resulting error.
It records no lease contents, credentials, raw attributes, or unrelated interfaces.
Capture and replay each reject encoded inputs larger than 65536 bytes.

The standalone Docker test captures a fresh namespace observation, then replays
that observation twice inside a separate container with networking disabled.
It also replays the recorded fixture and checks the exact same error.
The native regression independently checks the recorded fixture twice.
Missing capture files and malformed JSON fail without acquiring host observations.

`network-policy-guest.xsh` is the bounded failure-replay driver. It is
unchanged by the reconciliation work: it exercises the request/acknowledgement
transport in a disposable `qemu-self-hosting` guest and does not call the live
applier.
Before creating its own veth pair, it requires the exact `LAPUTA_SELF_HOSTING=1`
kernel token and a validated `qemu-self-hosting` generation receipt through the
existing PM reader. It requires observed absence of every selected default route
before and after its requests, so no selected default of any TOS is hidden.

The driver issues only two controlled requests under test: an exclusive address
addition and an invalid-gateway route addition. It checks the real error number,
retention of the added and foreign addresses, and continued default-route absence.
It replays the failed operation sequence and the resulting foreign-address
admission conflict. It performs no address deletion, recovery, or general apply.
Each request uses `linux.netlink_route_request` with a one-second exchange
deadline and an owned socket that closes on every path. Kernel refusals are
acknowledgement data: address addition must return errno 0, and the invalid
gateway must return errno 22 or 101. Transport or protocol errors abort the
fixture without retrying an operation whose outcome is unknown.

Successful execution emits bounded `NETWORK_FAILURE_CAPTURE` and
`NETWORK_ADMISSION_CAPTURE` JSON records, then `NETWORK_IPV4_FAILURE_REPLAY_OK`.
That marker establishes the bounded failure and replay checks, not convergence.

The acknowledged-request driver passed in a Linux 7.2.9 x86_64 KVM
`qemu-self-hosting` guest with a seed built from clean XSH revision `8dfb48d07`.
The address request returned an acknowledgement with errno 0. The kernel rejected
the invalid gateway with errno 101 as acknowledgement data. The added
`198.18.1.3/24` and foreign `198.18.0.2/24` addresses remained, and selected default
routes were absent before and after the requests. The guest run did not induce a
transport failure; the driver propagates such errors separately from ACK data.

`network-policy-vm-failure.json` is a failure record from the previous driver
using `linux.netlink_request`. The offline regression reconstructs `Precondition`,
`Applied(0)`, and `Failed(1)` from that record. It reproduces the plan and
re-observation error twice, checks retained partial state, and rejects implicit
ownership of the observed address. The new guest run qualifies the bounded replay
with the acknowledged-request transport; it does not establish convergence.

The earlier bounded-replay fixture establishes ownership through two fresh link
indices and reciprocal peer links. Its original core encoded `VETH_INFO_PEER`
as 2 instead of 1, so Linux auto-named the peer. The fixture uses the observed
peer name. The matching core used by the live qualification encodes 1.

The guest fixture imports the existing `lib.nettools_fixture` from the matching
frozen core. Checking that fixture requires both explicit module roots:

```sh
XSH_MODULE_PATH="$PWD:$XSH_ROOT/core" xsht check \
  tests/system/fixtures/network-policy-guest.xsh
```

The disposable guest invocation uses its installed matching core:

```sh
XSH_MODULE_PATH=/mnt/self-hosting/inputs/laputa:/usr/lib/xsh/core \
  /usr/bin/xsh \
  /mnt/self-hosting/inputs/laputa/tests/system/fixtures/network-policy-guest.xsh \
  disposable-vm
```

## Live IPv4 guest qualification

`tests/system/network_policy_live_vm.sh` runs the live witness in a private user
and network namespace inside an actual Linux x86_64 KVM guest:

```sh
bash tests/system/network_policy_live_vm.sh \
  /absolute/path/to/clean/x86_64-seed \
  /absolute/path/to/canonical-self-hosting/current
```

The host driver requires KVM access, QEMU, `mkfs.ext4`, Bash, Git, `jaq`, `rg`,
`sha256sum`, and tar with xz support. The supplied bundle must be canonical A,
generation `906009468ffe783b2078aacfe5f1002e7294a15ac57712e50a2d09766229a8a5`,
with Linux 7.2.9. The driver owns fresh disk copies and a 2-CPU, 4-GiB guest.
It validates the clean seed's manifest against the copied runners and core
archive. The private root receives the matching `xsh`, `xsht`, and complete
core tree before the witness runs. This is an explicit tool overlay on A.
The base generation receipt does not attest the overlaid tools. The bootstrap
uses built-in JSON to guard the exact canonical identity before replacing the
tools; only then does the replacement interpreter import PM and fully validate
the generation receipt before running the witness.

The driver prints its evidence directory under `.work/tmp/network-live.*` and
retains it after completion. `vm/console.log` records the actual transcript,
writer identities, installed runner hashes and guest markers. The directory
also holds source and staged-input hashes, the seed manifest, and source-root
hashes checked after the run. QEMU is canceled and reaped on success or failure.
Completion requires complete marker lines from the raw serial console and an
anchored writer-identity line. Embedded markers and QEMU diagnostics cannot
complete the proof.
The original root bundle remains unchanged. A skipped network test fails the
guest qualification.

On 2026-11-12, clean XSH `5cce5ddfd174e64cae5b3104071b7b604399b892` passed this
KVM witness: five cases passed with no skips. Its installed `xsh` SHA-256 was
`47658de9489d695c598c6c96edc8a8c2efcb092ff329b9110533ed8c94ec51e1`, and
`xsht` was `2242b9622ec703fd55db8f4793bfc8035aebf3c8b55b5e2ad059bd4520041d10`.
The native network-policy suite passed 48 cases with no skips. This evidence
qualifies that seed.

The final shared clean XSH `d7b4c9c85cbeefd20954156bd362805eabf4e35c` also
passed all five guest cases with no skips, using Laputa
`d3dddf0e3a80040ed577ae53118250e7faa78b0e`. Its installed `xsh` SHA-256 was
`653c12c5b52253afbe43d5454cc68757aa622f6d7ed3826ed74a0286f752ffdd`, and
`xsht` was `75283c9924f9e85edf5dd611c3137c8a0abba435b203d92df5b282648e86e725`.
The full PM receipt validation and matching core checks passed after tool
replacement. Retained evidence is `.work/tmp/network-live.XXIbBAjD`; source,
staged-input, seed and original-root hashes all verified. The owned QEMU was
canceled and reaped. This rerun qualifies the final shared seed for this witness.

The witness converges an owned IPv4 address and default route, then plans
nothing on reapplication. Foreign and peer addresses, an operator default on
the peer, and a Tailscale-like `100.64.0.0/10` route survive. A separate XSH
process changes the kernel address state after planning. Its distinct PID,
parent PID and shared network namespace are checked. Interprocess barriers
release the controller only after the writer's acknowledged mutation is
observed. The stale pass reports `NetworkReobserve` before operation 0 and
attempts no changes. A fresh observation then converges two route operations,
and reapplication again plans and attempts nothing. The writer is joined and
its added foreign address survives recovery.

The same witness retains zero-metric and unmodeled-attribute refusal before
effects, partial-state reporting after a refused route request, and full
re-observation after a real ENOBUFS notification overrun. No production network
code, dependency or installed payload changes were needed for this qualification.

This is deterministic second-process concurrency between planning and applying.
It does not establish atomicity between a per-operation check and its request,
or a shared generation across the four dumps in `linux.network_dump`. The
controller reports observed divergence and loss. It does not provide a kernel
transaction, persist ownership, supervise networking or prove packet delivery.

## Live IPv6 guest qualification

The same driver, `tests/system/network_policy_live_vm.sh`, executes the IPv6
cases: `network_policy_applier.xsh` runs the IPv4 witness and then
`ipv6_cohort` in one private user and network namespace inside the KVM guest, and
`network-policy-live-guest.xsh` requires each IPv6 transcript line and prints
`NETWORK_IPV6_LIVE_GUEST_OK`, which the host driver now also requires from the raw
console. A skipped case still fails the proof.

On 2026-11-14 it passed with clean XSH `befe5ced1ab8a75b1c92b21c55ed6d6b86f2d4bb`
as the tool overlay on canonical A (Linux 7.2.9, 2 CPUs, 4 GiB, KVM): all five
native cases passed with no skips, the host driver exited 0 with
`NETWORK_LIVE_KVM_HOST_OK`, and the four original-root hashes were unchanged.
The installed `xsh` SHA-256 was
`61fb3eceed9132a429afd642ec83af7166270b2745e627d87c994d2f0bdf5464` and `xsht` was
`051489f2e0fa87896472188f3d3944524b357078c03be7afd6de0371014d7a2b`. The tree ran
uncommitted on top of Laputa `6e4c90ec1add11b64607c22a7128404dbaf2bb9d`; the
retained evidence `.work/tmp/network-live.XXDdiFEf` holds the source hashes of the
ten files the driver records, which match the files at the time of writing.
`net_state.xsh` is byte-identical in that seed and in the XSH tree used for the
host runs.

The IPv6 cases, all in the guest and all deterministic across twelve host runs:

- A link with the stack disabled (`disable_ipv6 = 1`, the packaged policy) refuses
  the first address. The pass reports `NetworkDenied` for operation 0 and a
  re-observation request, adds nothing, and the link has no link-local address.
- With the stack enabled, one pass converges an owned `2001:db8:1::2/64` and a
  global-gateway default at metric 100. A foreign static address on the link, a
  lifetime-managed address added with `IFA_CACHEINFO`, the link-local addresses, a
  router-advertisement-protocol default (protocol 9), an operator static default
  and an operator route on the peer, and the IPv4 resources of the earlier cases
  all survive. The observed address settles to permanent once detection finishes.
- Reapplication plans nothing, attempts nothing, and leaves the full IPv6
  address and route view of the namespace unchanged.
- A separate process adds a different IPv6 address after planning. Its distinct
  PID, parent PID and network namespace are checked. The stale pass reports
  `NetworkReobserve` before operation 0 and attempts no change; the old address is
  kept, the replacement is never added, and the writer's address survives. A fresh
  observation then converges to a link-local gateway, and a second pass plans
  nothing.
- An intent metric of 0 means 1024. An advertised default at 1024 occupies that
  metric, so the kernel refuses the addition (`NetworkDenied`, re-observation),
  the advertised route and the owned metric-200 route both survive; once the
  advertised route is gone the pass converges, the observed route has priority
  1024 and the retired metric-200 route is removed.
- A real overrun of a one-byte receive buffer by forty IPv6 address additions
  requires a full observation, attempts nothing and keeps the old address.
- An address that a peer on the link already holds fails duplicate address
  detection (`IFA_F_DADFAILED`). The pass that adds it may return while detection
  is pending; every later observation and reconcile is refused with
  `selected IPv6 address failed duplicate address detection`.

Native tests cover the same guarantees over fixture States without effects:
malformed, partial and truncated dumps are errors, never an empty state;
consecutive dumps must agree; each family ignores the other's state; and every
forged, stale or zero-metric plan is refused before any request is encoded.

IPv6 limits:

- Convergence means the kernel holds the configuration. It does not mean the
  address passed duplicate address detection (reported on the next observation),
  that the gateway is reachable, or that packets are delivered.
- Router advertisements are foreign. The cohort cannot see an advertised
  default's metric, so a collision is caught by the kernel, not the plan. An
  operator who enables `accept_ra` or `autoconf` on a managed link gets
  kernel-moving state that the controller tolerates but never owns.
- The router preference value and the cache information in each route are not
  modeled by `net_state.Route`; only their attribute kinds are visible.
- A dual-stack link is two sequential passes, each with its own observation and
  precondition; there is no joint plan or cross-family atomicity. The four
  separate dumps, per-operation atomicity, the `sysctl` state itself, Linux
  aarch64, Asterinas and physical networking remain unqualified.
