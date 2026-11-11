# IPv4 network plan reference

`network_plan.xsh` provides an offline, read-only plan for one existing `veth`
or `dummy` virtual Ethernet interface. The package's installed `ifup` service
continues to own boot setup. The planner is a source-tree development command.

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
canonical IPv4 address with a prefix from 1 through 32, an IPv4 gateway, and a
nonnegative default-route metric.

`NetworkOwnership` grants authority over exact addresses and routes on that
interface. Observation does not grant ownership. A desired resource already
present without explicit ownership produces a conflict.

`NetworkSnapshot` describes the complete selected IPv4 cohort. Addresses identify
local address and prefix. Routes describe main-table unicast default routes on
the selected interface, with a gateway and metric. Other route tables, source
routes, multipath routes, IPv6, and physical interfaces have no representation
in this cohort. A host adapter must reject unsupported or incomplete observations
rather than discard information needed to recognize a conflict.

Each observed or owned list accepts at most 64 resources. Invalid addresses,
duplicate resources, and another default route using the desired metric fail.
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
checks or request bytes. It provides no live apply API, mutation runner, or
convergence result. The boot service and installed package payload remain
unchanged.

`network_change` validates the complete plan, then maps one operation onto a
`net_state.Change`. `net_state.request` encodes it. An address request carries
the interface index, local address, and prefix; a default-route request is a
main-table (254), boot-protocol (3), universe-scope, unicast route carrying the
gateway, interface index, and metric (omitted when 0) with the table attribute.
Removals send the same protocol and type, so they delete exactly the route this
controller adds and never a route of another protocol. Additions use exclusive
creation. Encoding bytes does not qualify their execution against an observed
host. `network_outcome` maps a kernel `Refused` verdict to `NetworkDenied` and any
other failure to `NetworkFailed`; `network_lost_events` maps a drained `Lost`
notice to `NetworkLostEvents`.

`network_project_dump` requires `net_state.project` to accept the dump: an
incomplete, interrupted, truncated or undecodable socket, link, address or route
dump is an error, never an empty state. `network_project_state` then requires the
selected independent virtual Ethernet interface. It rejects selected secondary
IPv4 addresses, point-to-point addresses, and unsupported selected default
routes. An empty projected route list therefore follows observed absence, never
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
two observations. General live application stays withheld pending convergence
qualification.

The projection checks all IPv4 preferred-source dependencies on selected
addresses, including routes through another interface. Its address-derived
exception requires zero flags, no source selector, boot-time kernel protocol,
one hop with no gateway out of the managed link, priority 0, and no unmodeled
attributes. Connected, local, and broadcast destinations must also match the
address's exact derived shape. This exception does not grant mutation authority.

## Verification boundary

```sh
XSH_MODULE_PATH="$PWD" xsht check packages/laputa-net/network_plan.xsh \
  tests/system/network_policy.xsh
XSH_MODULE_PATH="$PWD" xsht test tests/system/network_policy.xsh
XSH_MODULE_PATH="$PWD" xsht test tests/system/network_policy_kernel.xsh
XSH_MODULE_PATH="$PWD" xsht test tests/system/network_policy_input.xsh
bash tests/system/network_policy_docker.sh /absolute/path/to/xsh-tools
```

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

`network-policy-guest.xsh` is the bounded failure-replay driver.
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

The fixture establishes ownership through two fresh link indices and reciprocal
peer links. The supplied `lib.nettools_fixture.link_add_veth` encodes nested
`VETH_INFO_PEER` as 2, while the pinned Linux header defines 1. Linux consequently
auto-names that peer. The fixture brings up the observed peer name. The XSH helper
bug remains outside this Laputa change.

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

This slice adds no dependencies and changes no installed payload. It does not
persist ownership or supervise networking. LAP-32 remains blocked: address
withdrawal and general live application require qualification beyond the bounded
failure-replay driver; TOS is now observed and projected. XSH-38 and XSH-45 shared-boundary
qualification, concurrent-writer behaviour, IPv6, Linux aarch64, and Asterinas
remain unverified. The VM failure replay does not establish network convergence.
