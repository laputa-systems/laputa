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

`NetworkPlanInput` contains `intent`, `owned`, and `observed`. Missing fields,
malformed JSON, and inputs larger than 65536 bytes fail. Input files are trusted
observations supplied by the caller. The command never falls back to the host.

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

## Pure codec and limited projection

`network_kernel.xsh` exports only pure request encoding and read-only projection.
It provides no live apply API, mutation runner, or convergence result. The boot
service and installed package payload remain unchanged.

`network_encode_operation` validates the complete plan before encoding exact
route-netlink requests. Address requests include the interface index, local
address, and prefix. Default-route requests include the table, interface index,
gateway, and metric. Additions use exclusive creation. Encoding bytes does not
qualify their execution against an observed host.

`network_project_dump` requires a complete, issue-free native observation of the
selected independent virtual Ethernet interface. It rejects selected secondary
IPv4 addresses and nonempty selected default-route cohorts. An empty projected
route list therefore follows observed absence, never a fallback.

The fixed XSH observer omits the route header's TOS byte. An ordinary default
and a TOS-specific default can otherwise have identical typed records. Those
records cannot establish an ordinary-traffic default or safe address withdrawal.
The generic request collector discards dump completion and interruption details.
A second unqualified dump with matching counts cannot recover that missing proof.
LAP-32 live application remains blocked on a qualified route-header observation
that preserves TOS and the strict collector's completion guarantees.

For the XSH repair, compare route headers `02 18 00 00 fe 02 fd 01 00 00 00 00`
and `02 18 00 08 fe 02 fd 01 00 00 00 00 00` with identical table, destination,
preferred-source, and output-interface attributes. The pinned decoder's
`src/modules/linux/real/netlink.rs::parse_route` reads header offsets 0, 1, 2,
and 4 onward, omitting offset 3. Both messages therefore become the same typed
route despite different traffic selectors. Repeat with destination length zero
to cover false default-route convergence. The repair needs a typed TOS field
and decoder tests distinguishing both pairs; malformed and interrupted dump
rejection must remain intact.

The projection checks all IPv4 preferred-source dependencies on selected
addresses, including routes through another interface. Its address-derived
exception requires zero flags, no source selector, and exactly one unflagged
attribute for each of table, destination, preferred source, and output interface.
Every attribute's bytes must match the typed fields. Unknown attributes,
duplicates, custom metrics such as MTU, and changed flags fail closed. Connected,
local, and broadcast destinations must also match the address's exact derived
shape. This exception does not grant mutation authority.

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
TOS and do not establish route identity or convergence.

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
before and after its requests, so missing TOS cannot hide a selected default.

The driver issues only two controlled requests under test: an exclusive address
addition and an invalid-gateway route addition. It checks the real error number,
retention of the added and foreign addresses, and continued default-route absence.
It replays the failed operation sequence and the resulting foreign-address
admission conflict. It performs no address deletion, recovery, or general apply.
Each request owns a fresh socket with one-second send and receive timeouts and a
one-second reply deadline. Every return closes the socket.

Successful execution emits bounded `NETWORK_FAILURE_CAPTURE` and
`NETWORK_ADMISSION_CAPTURE` JSON records, then `NETWORK_IPV4_FAILURE_REPLAY_OK`.
That marker establishes the bounded failure and replay checks, not convergence.

The driver passed in the pinned Linux 7.2.9 x86_64 KVM `qemu-self-hosting` guest
with the supplied XSH and matching installed core. `network-policy-vm-failure.json`
is the resulting 1006-byte failure record. The exclusive `198.18.1.3/24` addition
remained after the kernel rejected gateway `192.0.2.1` with errno 101. The foreign
`198.18.0.2/24` address survived. Selected default routes were absent before and
after the requests, so the missing TOS field cannot hide a default in this case.

The offline regression reconstructs `Precondition`, `Applied(0)`, and `Failed(1)`
from that capture. It reproduces the same plan and re-observation error twice,
checks the retained partial state, and rejects implicit ownership of the observed
address. This qualifies LAP-37's bounded VM-to-native failure replay.

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
withdrawal, default-route identity, and general live application require the
qualified TOS observation described above. XSH-38 and XSH-45 shared-boundary
qualification, concurrent-writer behaviour, IPv6, Linux aarch64, and Asterinas
remain unverified. The VM failure replay does not establish network convergence.
