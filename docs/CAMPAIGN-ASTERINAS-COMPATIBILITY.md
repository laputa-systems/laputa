# Qualify Asterinas against Laputa consumers

## Status

- Goal: qualify the pinned x86_64 Asterinas/Firecracker baseline, then deliver
  device coldplug, clock discipline, and IPv4 network compatibility.
- State: A0 accepted as a baseline. The guest `NoMemory` slice is delivered and
  A1 (device coldplug) delivers its consumer path, but D2 stays open (see the
  obligations below). A2 clock ABI exists with open obligations (below); A3 is accepted for the loopback fixture and for pause and resume against an outside peer, A4 is accepted, A5 is accepted for the packaged DHCP client (remaining obligations are successor debt, below). A6 is not accepted. It has run its integration, cancellation and native-accounting checks and the independent review's findings are resolved, but it needs D2 (device compatibility) delivered and A0's no-new-failure rule to hold, and 14 `test-bb-awk` cases that passed at A0 time out at A6 (the awk lane owns that cause).
- Verdict: the paired boot and numeric cases pass on both backends. Native
  accounting closes on the two-hour fan-out budget with every remaining case
  retained as unexecuted; the campaign does not promise full native-suite
  compatibility. The Asterinas-only failures below are debt, not passes.
- Survey revision: Laputa `aee5090ea11188dc853ec38297c03ade620f359c`.
- `bash infra/asterinas/qualify.sh baseline --backend both --case boot` passed.
  The `numeric` case passed five tests on each backend with the same PM root.
  A previous test environment loaded duplicate module roots. The corrected
  single-VM full run discovered all 15,255 host identities, then stopped after
  26 passed, one failed, and four skipped. The failing case was
  `core/tests/test-awk.xsh::test_awk_matrix_arithmetic_and_bit_functions_shard_000`:
  `status was not an exit`. The other 15,224 cases have no result. The Linux
  full run reached its 3,000-second limit without releasing buffered output,
  so its individual outcomes are unknown. A later streamed Linux run reached
  the same limit after 187 passed and four skipped, with no reported failure;
  15,064 cases were unexecuted. Its last passed case was
  `core/tests/test-awk.xsh::test_awk_matrix_printf_shard_005`.
  Separately selected Asterinas modules remain open.
- Loop repair: a warm one-module run took 4 to 8 minutes because the selection
  sat in the PM generation overlay, so each module rebuilt the generation, the
  512 MiB ext2 image, the bundle and a runtime copy (compose alone 5m44s, about
  1.5 GiB of disk per module). The selection is now a run input written into the
  disposable root copy, and `XSH_TEST` takes several selections for one guest.
  A cached-bundle two-module run took 3m57s at the same host load; a batch run
  with a cached bundle and root copy is about 40 s plus test time. The guest
  also stopped using `--fail-fast`, so one failure no longer hides later cases.
- Batched native accounting, Asterinas, four 50-module batches (200 of 1,015
  modules attempted, 133 started, 882 unstarted). Of the 15,255 host
  identities: 1,281 passed, 71 failed, 65 skipped, 13,838 unexecuted. Three
  batches ended in a kernel panic, `spawn task failed: NoMemory` or a
  ring-buffer `NoMemory` unwrap, after about 10 to 13 minutes in a 4 GiB guest.
  The module in flight at each panic (`test-bb-md5sum`, `test-bb-sha256sum`,
  `test-diff`; 26 observed cases) is counted unexecuted. Failures recorded in
  the three panicking batches are not confirmed in a fresh guest. The third
  batch ran all 50 modules. The fan-out budget (two hours) was spent: 66 minutes
  in the superseded one-module loop and 54 minutes in batches. The owner
  declined to extend the budget. The remaining 13,838 cases stay unexecuted
  baseline debt; completing them would need roughly four to five more hours at
  about one case per second.
- Paired Linux/QEMU run of the same corpus for the 61 modules that contain the
  Asterinas failures plus the clean batch: 700 cases, 649 passed, 42 failed,
  9 skipped, no unexecuted case. Of the 700, Asterinas failed 32 that Linux
  passed (listed below) and Linux failed 3 that Asterinas passed
  (`test-bb-awk` assign_while_test, two `test-cp` ACL/xattr cases). The remaining
  failures occur on both and are environment debt, including
  `test_bb_cp_cp_does_not_copy_unreadable_file`: the guest runs as root on both
  sides, so that case is a fixture mismatch, not an Asterinas defect.
- The awk failures are not hangs: they are CPU-bound cases cut off by a fixed 5 s
  limit on a loaded host (see the A6 native accounting). In a fresh guest
  `core/tests/test-bb-awk.xsh` passes 16 cases and then 33 cases hit
  `process timed out` while Linux passes 38 of 49; chrt, sparse `dd` and
  `cpio`/`date` differences are listed below. The `NoMemory` panics are a
  separate kernel memory exhaustion that bounds guest lifetime.
- Guest `NoMemory`: a fresh-guest batch panicked as `spawn task failed: NoMemory`
  or a ring-buffer `NoMemory` unwrap with gigabytes reported free. An
  instrumented run showed 703 MB free while this CPU's local pool and the global
  pool held 9 MB; the rest sat in the other CPU's local pool. Fixing that exposed
  three more defects in turn: a frame-cache refill that demanded eight
  contiguous frames, a pool balancer that recursed exponentially once only small
  chunks remained, and a 128-frame contiguous kernel stack. The kernel commit
  fixes all four and adds
  `process/pthread/pthread_create_fragmented_memory`, which fails on the
  unfixed kernel and passes on the fixed kernel and on Linux
  (`bash infra/asterinas/run-witness.sh asterinas|linux SOURCE.c DIR`). Known
  remaining limit: pipe ring buffers and large kernel heap allocations still
  need contiguous frames and fail the same way under extreme fragmentation. It
  becomes a slice only if a required case hits it. The existing 9 frame-allocator
  and 221 OSTD kernel tests pass on the fixed kernel, and three new frame
  allocator tests cover cross-CPU reclaim and bounded balancing
  (`bash infra/asterinas/run-ktest.sh osdk/deps/frame-allocator`); the
  single-segment refill fallback and per-frame kernel stacks are covered only by
  the witness. The
  batch-level panics were not reproduced on demand (a rerun of the first batch
  passed), so the whole-corpus effect is unmeasured until the fan-out is rerun.
  The awk timeouts do not share this cause.
- A1 device coldplug: the packaged `mdevd` and `mdevd-coldplug` (the `mdevd-rs`
  package, now part of the Asterinas generation) run in the guest and the
  explicit coldplug bypass is gone. The kernel publishes block devices in a
  `block` class (`/sys/class/block`, `/sys/dev/block`, the `/dev` node, all from
  the device model), gives every device a `uevent` attribute (read: MAJOR, MINOR,
  DEVNAME, DEVTYPE; write `add`: a kernel uevent to group 1, EINVAL for an
  unknown action), and lets a uevent socket with CAP_NET_ADMIN send to groups,
  which is how mdevd answers the coldplug sync. The guest proof coldplugs at
  boot, then three times with the node removed (the node returns with the
  sysfs device number, mode 0660, group disk), then with the daemon killed
  (coldplug without a daemon fails within 3 s and creates no node), then with a
  restarted daemon. The identical payload passes on the Linux reference.
  `device/block_uevent` is the kernel witness: it passes on this kernel and on
  Linux. D2 is not delivered. Open D2 obligations:
  `DEVPATH` is `/devices/virtual/block/vda`, not a PCI or MMIO path, so it does
  not match Linux; partitions are not nested below their disk; no add event is
  emitted at device registration or hotplug; only the virtio disk is a fixture
  device, and ownership and mode are checked for it only; the kernel crate's
  unit tests do not build in the OSDK harness here (they stop at a grub
  video-mode error), so the kernel-level uevent code has no unit test beyond the
  17 device model tests and the `device/block_uevent` witness.
- A2 clock ABI: `clock_settime`, `adjtimex` and `clock_adjtime` exist and
  CLOCK_REALTIME is a settable, steerable function of the monotonic clock. The
  `time/clock_adjust` witness and 10 `aster-time` kernel tests cover readback,
  positive and negative nanosecond and microsecond steps, frequency sign and
  size (±200 ppm measured against CLOCK_MONOTONIC_RAW), vDSO and system call
  agreement, `EINVAL` for invalid times, steps and clocks, `EOPNOTSUPP` for other
  clocks, and `EPERM` without CAP_SYS_TIME while reading stays open. The witness
  passes on this kernel and on Linux. Open A2 obligations, not delivered: the
  frequency correction does not slew CLOCK_MONOTONIC or CLOCK_BOOTTIME (Linux
  slews both), so the daemon's monotonic measurements differ from Linux by the
  correction; leap seconds are not applied, and ADJ_OFFSET, ADJ_TICK, the adjtime
  modes, STA_PLL, STA_FLL, STA_INS, STA_DEL and STA_FREQHOLD fail with `EINVAL`
  where Linux accepts them; absolute realtime timers are not re-armed by a step;
  `settimeofday` is still missing; while a frequency correction is active the
  vDSO reads through the system call.
- A3 disciplined clock consumer: accepted for the loopback fixture. The case
  `guest/asterinas/clock` runs the packaged ntpd-rs under `xinit supervise` as
  UID/GID 123 with only CAP_SYS_TIME against a controlled in-guest source. `behind`
  and `ahead` start 10.1 s off, require a startup step, and then five consecutive
  one-second samples within 100 ms; `frequency` runs a 100 ppm source and requires
  the saved correction within 20 ppm of it; every mode kills the daemon and
  requires a restart that reports unsynchronized (and, for `frequency`, restores
  the saved correction) without a source. Readiness is checked not to mean
  synchronization. All three pass on Asterinas and on the Linux reference.
  Unblocking it took IPv4 datagram ancillary data: `IP_PKTINFO`, `SO_TIMESTAMP`,
  `SO_TIMESTAMPNS`, `SO_TIMESTAMPING` software receive and transmit timestamps
  with the `MSG_ERRQUEUE` queue and poll error events, and a fix so that an
  unprivileged program may bind or connect port 0. The `network/udp_ancillary`
  witness passes on both kernels. The earlier Linux `behind` flake was not source
  latency: 10 s is the daemon's own step threshold, so a start exactly 10 s off
  steps or slews at 500 ppm depending on sub-millisecond noise. The fixture now
  starts 10.1 s off; the acceptance bounds are unchanged. Open A3 obligations:
  transmit timestamps without `OPT_TSONLY` and hardware timestamping are
  unsupported; and the Firecracker guest has no RTC, so its clock starts at
  1970-01-01 (the case sets a fixture epoch then, except in `pause` and `jump`,
  which align the clock with the peer first).
- A3 pause and resume, accepted: `LAPUTA_GUEST_NETWORK=tap bash
  infra/asterinas/run-guest-case.sh asterinas|linux guest/asterinas/clock pause|jump DIR`.
  The NTP peer is a C server on the container end of the TAP (`192.0.2.1:123`, the
  container's wall clock, which the case never changes); the packaged ntpd-rs runs
  under `xinit supervise` as UID/GID 123 with only CAP_SYS_TIME and polls it. A
  case that ships `vmm-control.sh` gets a VMM control socket: the Firecracker API
  socket (`--api-sock`, `PATCH /vm` `Paused` and `Resumed`) on Asterinas and a QMP
  socket (`stop`, `cont`, through `system.qemu`) on the Linux reference. The guest
  asks the peer for a pause over UDP and the peer, which keeps serving time,
  pauses the VMM for 5 s and answers after the resume, so the trigger needs no
  console polling. An independent SNTP probe in the guest measures the offset to the
  peer and the guest's `CLOCK_REALTIME`, `CLOCK_MONOTONIC` and `CLOCK_BOOTTIME` across
  the pause, separately from the daemon. Asterinas on Firecracker: all three guest
  clocks advance by the pause (5.03 to 5.06 s against 5.03 to 5.06 s held), the
  offset to the peer after resume is 0.2 ms, the daemon never restarts or leaves
  the ready state, and five consecutive samples are within 100 ms at once (the
  gate is five samples within 120 s). Deliberate difference: on the Linux
  reference QEMU's `stop` and `cont` freeze the guest clocks, so the guest loses
  the pause (about 1 s of the 6.9 s the peer held it passes) and its wall clock
  lags the peer by 5.9 s. That is below the daemon's step threshold, so ntpd-rs slews
  at about 500 ppm and cannot meet the 120 s recovery bound (the Linux reference
  fails the bound as written); the case therefore branches on the measured loss
  and, for a VMM that hides the pause, requires the guest clocks to agree with each
  other, the offset to equal the loss within 0.5 s, the daemon to remain
  uninterrupted and the offset to shrink. The Asterinas gate is the strict
  branch. The wall step that the campaign's pause criterion presumes therefore
  never reaches the Asterinas guest through a Firecracker pause; it is reached by the
  `jump` mode instead. `jump` steps the running guest's clock back 5 s: on both
  kernels the daemon rejects the external jump and exits, `xinit` restarts it
  (identity and capabilities rechecked, restart count raised), the restarted daemon
  selects the peer and steers toward it (5.001 s to 4.995 s in 10 s); 5 s is below
  the step threshold so no recovery bound applies. Rejection of a jump above the
  single-step panic threshold (1000 s) is not exercised. Contract changes: the
  Linux reference guest may expose a QMP control socket
  (`QemuReferenceControl`, `run-linux.xsh --qmp`), and `run-test-vm.sh` starts
  Firecracker with an API socket when `LAPUTA_VMM_CONTROL` is set. No kernel change
  was needed.
- A4 IPv4 state operations, in progress. Method: the Linux reference guest and the
  Asterinas guest each get a virtio-net `eth0` wired to an owned TAP in a disposable
  container namespace (`LAPUTA_GUEST_NETWORK=tap`), and
  `bash infra/asterinas/qualify.sh network-state --backend both` runs the cohort's
  netlink witnesses on both kernels, then the `guest/asterinas/network-state` case
  and requires identical `NET_` transcripts (the reference `sit0` link is omitted
  and IPv6 route and rule lines are not compared, because the reference kernel has
  no IPv6 policy routing). Delivered: route and rule dumps (`RTM_GETROUTE`,
  `RTM_GETRULE` with IPv4 before IPv6, table and address order, Linux attribute
  order, protocol, scope and type) and the network-layer link MTU (eth0 1500, lo
  65536); the loopback transcript matches Linux and `network/rtnl_route_dump`
  passes on both kernels. Interface state: `eth0` now starts down with no address
  or route like a Linux Ethernet device (the hard-coded `10.0.2.15/24` and gateway
  are gone), `SIOCSIFFLAGS` changes `IFF_UP` (`link_up` and `link_down`, with
  `CAP_NET_ADMIN`; any other changeable flag fails with `EOPNOTSUPP`), a down
  interface drops its traffic and reports `IFLA_OPERSTATE`, and the route managers
  are mutable: down removes the connected, broadcast and user routes and keeps the
  host's local routes, as the Linux reference does. Verified by
  `network/rtnl_route_dump` and `network/link_state` on both kernels and by the
  `loopback` and `link` transcripts of the cohort. Contract changes: the route and
  rule dumps no longer fail with `EOPNOTSUPP`; the MTU values changed; `eth0`
  starts down and unconfigured; `SIOCSIFFLAGS` exists. A route request without
  `NLM_F_DUMP` (route lookup) still fails with `EOPNOTSUPP`. The A3 clock case
  (behind, ahead, frequency) and the paired boot and numeric cases pass after each
  slice. Addresses: `RTM_NEWADDR` and `RTM_DELADDR` assign and remove IPv4
  addresses with the Linux rules (several addresses per interface, up to eight
  entries including IPv6; an address on the network of an existing one with the same
  prefix length is secondary and sorts last; adding the same address fails with
  `EEXIST`, removing a primary address removes its secondaries, removing an unknown
  one fails with `EADDRNOTAVAIL`; `EINVAL` for a prefix over 32 or no address,
  `ENODEV` for an unknown interface, `EPERM` without `CAP_NET_ADMIN`; a success
  is acknowledged only when the request asks). The kernel derives the local,
  connected and broadcast routes from the addresses and reports `IFA_CACHEINFO`.
  The data plane serves every address, and a guest TCP connection through a
  netlink-configured `eth0` reaches the outside peer and is refused by it exactly as
  on Linux (`network/addr_config` on both kernels, and the `address` transcript).
  Fail-loud gaps, all `EOPNOTSUPP`: `NLM_F_REPLACE`, IPv6 addresses, peer addresses,
  finite lifetimes, address flags other than permanent. Contract changes:
  `RTM_NEWADDR` and `RTM_DELADDR` exist; `RTM_GETADDR` reports the assigned
  broadcast and `IFA_CACHEINFO`; `SIOCGIFCONF` lists each address under its label;
  `SIOCGIFBRDADDR` returns only an assigned broadcast. Routes: `RTM_NEWROUTE` and
  `RTM_DELROUTE` install and remove unicast IPv4 routes with the Linux rules the
  XSH DHCP consumer relies on (metric as identity, `EEXIST` for a duplicate,
  `ESRCH` for a missing route, `ENETUNREACH` for a gateway off the connected
  networks or an unknown interface with a gateway, `ENODEV` without one, `ENETDOWN`
  on a down link, `EINVAL` for host bits or a prefix over 32; user routes leave
  with a link-down and with the last address of their interface but survive the
  removal of another address; removal filters match destination, metric, gateway,
  interface, protocol, type and scope). Gateway routes in the main table also feed
  the interface's next-hop selection. `network/route_config` passes on both kernels
  and the `route` transcript is identical to Linux. Fail-loud gaps, all
  `EOPNOTSUPP`: other route types, source, TOS, preferred source and flags,
  replace and append, and removal of the routes the kernel derives from
  addresses (Linux allows it). Acknowledgements and errors: `network/rtnl_ack`
  passes on both kernels. An unknown message type fails with `EOPNOTSUPP`, a
  request that changes state with a body shorter than the full one fails with
  `EINVAL` (the witness found the first implementation reading the one-byte legacy
  body of a delete as "remove the first address"; only reads accept it), an
  acknowledgement carries `NLMSG_ERROR` with error 0 and the request header, a
  failure carries its errno under the request's sequence, several requests in one
  datagram get one reply each in order, and a dump ends with a multipart `NLMSG_DONE`
  and is never acknowledged. Deliberate difference: Linux ignores a malformed trailing
  attribute and Asterinas rejects it with `EINVAL`; error replies carry the request
  header but not its payload. Notifications: `SIOCSIFFLAGS`,
  `RTM_NEWADDR`, `RTM_DELADDR`, `RTM_NEWROUTE` and `RTM_DELROUTE` publish to the link, IPv4 address and
  IPv4 route groups, in order and under the lock that orders the changes. The order and content
  follow Linux, checked by the `network/rtnl_notify` witness on `lo` (one message per datagram, the
  requester sees notifications before its acknowledgement, `NETLINK_ADD_MEMBERSHIP` by group number,
  one `ENOBUFS` then the queued messages on overflow) and by the `events` mode of the
  `network-state` case on the TAP-backed `eth0`, whose 65-line transcript is identical to Linux. An
  address message comes first, then its routes (added: local, assigned broadcast, connected, subnet
  broadcast; removed: connected, broadcast, local); a secondary address goes before its primary;
  address and user-route messages echo the request's sequence and port, derived routes carry
  neither; link up announces the routes that return; link down and removal of the last address flush
  routes without announcing them; a down interface gains only its own address routes. Contract
  changes: route netlink sends notifications; `NETLINK_ADD_MEMBERSHIP` and `NETLINK_DROP_MEMBERSHIP`
  take a group number (they were a bit mask), a successful acknowledgement carries `NLM_F_CAPPED`,
  and a down interface no longer gains its connected route on the loopback device. Deliberate
  difference: Linux reports the operational state of a link as a second, delayed message (change
  mask 0, at most one per second); Asterinas has no deferred link watch, so its single message
  carries the final flags, and the `events` transcript drops the change-0 message and does not
  compare the link flags. `MSG_DONTWAIT` is still ignored by netlink receive (use a non-blocking
  socket). Still to build: `RTM_NEWLINK` (the XSH `link_up` uses the ioctl, so netlink link changes have
  no consumer yet). Open obligations: the `IFLA_CARRIER` attribute and carrier-change events
  needed by A5, IPv6 state, `SIOCSIFADDR` and `SIOCADDRT` (used by `ifconfig` and
  `route`, not by the maintained DHCP path), address expiry, and route lookup
  (`RTM_GETROUTE` without `NLM_F_DUMP`, which fails with `EOPNOTSUPP` where Linux
  answers).
- A5 prerequisites, found by reading the packaged DHCP client (`core/lib/dhcp_live.xsh`
  at the XSH pin): it sends and receives DHCP and ARP frames through `AF_PACKET`
  sockets bound to the interface and listens on a route-netlink socket joined to the
  link, address and route groups, treating `ENOBUFS` as a lost notification. The
  kernel lacked both: `AF_PACKET` is only a constant (`socket(2)` fails with
  `EAFNOSUPPORT`); route netlink notifications now exist (see A4). `AF_PACKET` is therefore the
  first A5 slice, ahead of the lease, renewal and carrier cases, and the A3
  pause and resume case needed an outside peer program in the container
  namespace (now delivered, see A3). The same client's UDP socket also sets `SO_BINDTODEVICE`, which the
  kernel does not have (`setsockopt` fails with `ENOPROTOOPT`); it belongs to the
  A5 lease slice. `AF_PACKET` is delivered in four slices. Create and bind: a
  packet socket needs `CAP_NET_RAW` (`EPERM`), takes `SOCK_RAW` or `SOCK_DGRAM`
  (other types fail with `ESOCKTNOSUPPORT`), keeps the EtherType given to
  `socket(2)`, binds with `struct sockaddr_ll` (`EINVAL` for a short or foreign
  address, `ENODEV` for an unknown index, protocol zero keeps the protocol) and
  reports protocol, index, hardware type and link-layer address from
  `getsockname(2)` with the Linux length; connect, listen, accept, shutdown and
  getpeername fail with `EOPNOTSUPP`, as do send and receive until their slices.
  `network/packet_bind` passes on both kernels (its first run caught the protocol
  kept in network byte order); the network-state cohort, the A3 clock cases and
  the paired boot and numeric cases pass. Contract change: `socket(AF_PACKET)`
  exists, and the socket address layer has a packet variant. Receive: an
  interface lets link-layer taps observe the frames it receives, and only the
  taps that select every EtherType (`ETH_P_ALL`) the frames it sends, as Linux
  does. A packet socket queues whole Ethernet frames (212992 bytes, then drops),
  reports the frame kind (host, broadcast, multicast, other host, outgoing) and the
  source address (reported with the full 20-byte `sockaddr_ll`, where
  `getsockname` stops at the link-layer address), strips the header for
  `SOCK_DGRAM`, honours `MSG_PEEK`, `MSG_TRUNC` and `MSG_DONTWAIT`, and polls
  readable or in error. Like Linux, taking a selected interface down fails the
  next receive once with `ENETDOWN` (and so does selecting a down interface with
  a protocol), poll reports an error until that receive, and bringing the
  interface up resumes reception. Taking an interface down now forgets its ARP
  cache, as Linux does (the packet transcript found the second probe not asking
  again). `network/packet_receive` checks that state machine against Linux; the
  `packet` mode of the network-state case compares the frames a TAP-backed `eth0`
  sees for an ARP exchange and a refused TCP connection, socket by socket,
  between the kernels. Deliberate difference: frames between two local addresses
  never reach a device in this stack, so loopback traffic of that kind is not
  visible to packet sockets (Linux shows it); frames injected through a packet
  socket do (slice 3). Known limit: the frame length of an ARP frame is compared,
  the length of a TCP segment is not (options differ). Contract changes: packet
  sockets receive; `bigtcp` gains link-layer taps. Send: `send`, `sendto` and
  `sendmsg` put a frame on the interface. `SOCK_RAW` sends its bytes as a whole
  frame (`EINVAL` below the 14-byte header, `EMSGSIZE` above MTU plus header);
  `SOCK_DGRAM` adds the Ethernet header from the socket address and the interface
  address (`EMSGSIZE` above the MTU). Without an address the socket uses its bound
  interface, else `ENXIO`; an unknown interface is `ENXIO`, a down one
  `ENETDOWN`, a link-layer address over eight bytes `EINVAL`, a busy device
  `ENOBUFS`. The `ETH_P_ALL` taps see the frame as outgoing except the sender. An
  interface without link framing (loopback) takes the payload and receives it
  again, so an injected IP packet is processed by the stack and seen by receivers
  as incoming. `network/packet_send` (on loopback with a local address, because a
  loopback source address is martian for injected frames on Linux) checks the
  delivery, the observers (outgoing, then host) and the errors against Linux, and
  the `packet` mode sends a raw ARP request and a broadcast UDP frame through the
  TAP-backed `eth0` with an identical transcript. Deliberate differences: a
  cooked socket without a destination fails with `EINVAL` (Linux succeeds and
  sends a frame without a header); loopback carries only IPv4 and IPv6 frames
  (`EOPNOTSUPP` otherwise) and does not keep the link-layer addresses of a frame.
  Contract changes: packet sockets send; `Iface::send_link_frame` exists.
  The `packet` transcript leaves out the peer's neighbor checks (its unicast ARP
  requests and the guest's answers), because the peer's kernel sends them five
  seconds after it last used the entry, which a loaded host reaches.
  Options: `SOL_SOCKET` options work on a packet socket (`SO_TYPE`, `SO_ERROR`
  reads and clears the `ENETDOWN` that poll reports, `SO_RCVBUF` sets the queue
  size in bytes with a 212992 default, `SO_RCVTIMEO` bounds a blocking receive),
  and `SOL_PACKET` has `PACKET_IGNORE_OUTGOING` (get and set) and
  `PACKET_STATISTICS` (frames that matched, including the dropped ones, and the
  frames that did not fit; read once, then reset). Every other `SOL_PACKET`
  option fails with `ENOPROTOOPT`, including `PACKET_AUXDATA`, membership, rings,
  fanout and filters, which no maintained consumer uses. Deliberate difference:
  `SO_RCVBUF` is not doubled and counts frame bytes, where Linux doubles it and
  counts buffer memory. `network/packet_options` and the additions to
  `network/packet_send` (ignore-outgoing, a flooded queue with its statistics)
  pass on both kernels. Contract change: the `SOL_PACKET` option level exists.
  AF_PACKET is complete for the DHCP client's use.
- A5 DHCP cohort, delivered for the packaged `dhcpc` against a scripted server.
  `bash infra/asterinas/qualify.sh network --backend both [--case NAME]` runs two
  kernel witnesses (`fs/procfs/proc_boot_id`, `network/udp_device`) and eight modes of
  `guest/asterinas/dhcp` on both kernels, comparing the `NET_` transcripts. The peer is
  the XSH pin's scripted DHCP server (`core/tests/support/dhcp_server.xsh`) on the
  container end of the TAP, which `run-guest-case.sh` starts when the case has a
  `peer.sh`; the `tcp` mode adds a C server for a deterministic 1 MiB payload. The
  client runs unmodified in the guest and the case watches it with a capture socket:
  `lease-acquire` (discover, request, address, default route and resolver, with a
  foreign address on `lo` and a foreign resolver line surviving), `lifecycle` (20 s
  lease; the renewal is unicast, the rebinding broadcast, and expiry withdraws the owned
  address, route and resolver line), `renewal` (acknowledged renewals), `nak` (a NAK to
  a renewal restarts acquisition and a new lease binds), `restart` (SIGKILL, then a
  restart reuses the remembered lease with one request, one address, one route),
  `carrier` (three link-down and link-up cycles: `no_link`, owned routes withdrawn,
  bound again with one owner) and `tcp` (1 MiB verified before, across a link cycle
  and after; on both kernels the connection survives, and the case would accept an
  explicit failure followed by a new connection). Running the client found five
  kernel gaps, each fixed with a witness that passes on Linux and on this kernel:
  `/proc/sys/kernel/random/boot_id` was missing; `SO_BINDTODEVICE` failed with
  `ENOPROTOOPT`; a UDP socket could not bind the unspecified address or receive on it
  (bigtcp matched the destination address exactly, and smoltcp asserted on a wildcard
  endpoint); a packet-socket send ignored the `ENETDOWN` that a link cycle leaves,
  where Linux fails the next send with it, so the client never read again after
  the first cycle (poll kept reporting the error); and netlink `recv` ignored
  `MSG_DONTWAIT`. Link messages now carry `IFLA_CARRIER`. Contract changes:
  `SO_BINDTODEVICE` exists for UDP sockets; a UDP socket with a device may bind the
  unspecified address and receives for any address of that interface; the boot
  identity file exists; link dumps and notifications carry `IFLA_CARRIER`; netlink
  receive honours `MSG_DONTWAIT`; a packet send reports and clears the pending
  error. Deliberate differences: binding the unspecified address without a device
  still fails `EADDRNOTAVAIL` (Linux binds every interface) and a bound socket
  cannot change its device (`EOPNOTSUPP`); the first UDP datagram to a neighbor
  that is not resolved yet is dropped while ARP runs (Linux queues it), so the
  modes with unicast renewals resolve the server neighbor first or the T1 renewal
  is lost and the T2 rebinding recovers; every interface has carrier, because
  Firecracker's virtio-net has no link status, so the case drives carrier loss and
  return with administrative link down and up (QEMU's `set_link` would move the
  Linux side only), which on both kernels clears `IFF_LOWER_UP` and
  `IFLA_OPERSTATE` while `IFLA_CARRIER` stays 1. The `reconfigure` mode covers a lease
  whose DNS servers and routes change at renewal: the first acknowledgement carries the
  server as router and resolver; the renewal carries two other resolvers and two RFC 3442
  routes (one through the server, one on-link) and no router. The case first installs two
  foreign unicast routes with the static protocol (a network route through the server and a
  default route through another gateway at a worse metric). The transcript is identical to
  Linux: the owned default route is withdrawn, the two classless routes appear with the DHCP
  protocol, the resolver lines are replaced, and both foreign routes and the foreign resolver
  line survive. A foreign route cannot survive lease expiry (the kernel drops the routes of an
  interface that loses its last address), so expiry is checked with the foreign address and
  resolver line only. A5 acceptance (the A5 row and D5) needs nothing more. The remaining A5
  obligations are successor debt that no capability claims: the syslog consumer (no case runs
  it; the maintained-VM successor owns persistent diagnostics), foreign routes of types other
  than unicast (`EOPNOTSUPP`), `IFLA_CARRIER_CHANGES` and the carrier counters, and the
  unresolved-neighbor queue (the cases resolve the neighbor first).
- Steering checkpoint after A4 slices 1 to 5: landed behavior is Linux-identical
  IPv4 state operations (route and rule dumps, link up and down, addresses,
  routes, acknowledgements and errors) proven by five kernel witnesses and four
  transcripts on both kernels, with the A3 clock case and the paired boot and
  numeric cases intact after every slice. The limiting factor is no longer
  state but delivery: notifications and `AF_PACKET`. Continue serialized with
  notifications, then `AF_PACKET`, then the DHCP cohort.
- Steering checkpoint after A4 notifications: landed behavior is Linux-identical change delivery on
  the link, address and route groups (loopback witness and eth0 transcript), with the clock cases
  (behind, ahead, frequency) and the paired boot and numeric cases intact. The limiting factor is
  now the packet path: the DHCP client cannot open its sockets. Continue serialized with
  `AF_PACKET` (create and bind, receive, send, options), then the DHCP cohort.
- Red boundary: the pinned kernel is 10 local commits beyond the advertised
  fork branch. GitHub cannot resolve its SHA. Distributed reproduction is blocked.
- Tooling: `infra/asterinas/native-batches.sh asterinas|linux MODULES BATCH BUDGET DIR`
  runs panic-bounded batches on either backend, and `account-native.sh` counts
  passed, failed, skipped, unexecuted and unknown cases, and rejects an empty
  result, an undiscovered case, or a case that passed at a given baseline and no
  longer does. The host fixtures exercise a red-to-green change, a regression,
  persistent debt, a missing result and an in-flight module. A three-module run
  through both backends gave identical results, and the paired boot and numeric
  cases still pass after the refactor (unchanged Linux consumer). No real
  Asterinas failure has gone red-to-green yet; the first kernel fix will be that
  check.
- Cold setup, from file times: fetching and building Firecracker, the initramfs
  and the kernel took about 28 minutes (08:46 to 09:13). Warm kernel rebuild
  21.6 s. Warm native run: see the loop repair above.
- Steering checkpoint after A0: landed behavior is a measured, repaired
  qualification loop and an explicit baseline, not compatibility. The limiting
  factor is guest memory exhaustion, which stops every run after ten to thirteen
  minutes. Continue serialized: kernel
  `NoMemory` diagnosis first, then A1. Fresh public-source reproduction and
  performance remain open.
- A6 integrate and harden, run on kernel `006f33dbc`. `bash infra/asterinas/qualify.sh all --backend both` now exists
  and runs, serially, `baseline` (boot, numeric), `device` (boot proof and the `device/block_uevent` witness),
  `clock-abi`, `clock` (the `udp_ancillary` witness and the modes behind, ahead, frequency, pause, jump),
  `network-state` (10 witnesses, 6 modes), `network` (2 witnesses, 8 modes) and `recovery` (the boot proof and the
  DHCP `restart` and `carrier` modes, 10 rounds). The final run exited 0 on both backends with no failed, skipped or
  missing case. The first run of the same tree failed only `clock pause` on Asterinas with
  `parse-int: invalid integer -12`: the case parsed the probe's signed offset with `parse_int_decimal`, which rejects a
  sign, so any negative sample failed it (fixed with `parse_int`; the Linux side was exposed to the same bug). Cleanup:
  SIGTERM or SIGINT to `run-guest-case.sh`, `run-witness.sh`, `native-batches.sh`, `qualify-cohort.sh` or `qualify.sh`
  leaves no owned VMM, container, peer or TAP; before the change SIGTERM left the container,
  Firecracker and the peer running (container `laputa-asterinas-case-PID`, TAP inside its namespace). The independent
  review found that an interrupt sent to a nested runner was ignored (bash starts background children with SIGINT
  ignored), that a signal between starting a child and recording its pid left the child running, that the container could
  be removed before it existed, that the 10 s escalation could kill `qualify-cohort.sh` before it removed its results, and
  that the two backends ran in parallel although the cases are timing sensitive. The runners now start children with
  SIGINT at its default, record a signal that arrives while a child starts, stop the child before removing its named
  container (and remove it again after a normal exit), run every docker step through the same cancellable path, and give
  each nesting level three seconds less to stop its child than its parent has, so a parent never kills a runner that is
  still cleaning up. The backends run one after the other, and `tests/system/asterinas_runners.sh` keeps these cases.
  Bad guest output: a case that fails, a case that prints the success markers and then fails, and a case that never
  completes are all rejected on both backends; a case that printed only `LAPUTA_ASTERINAS_CASE_OK` and `TEST_OK` was
  accepted on Asterinas (only the Linux path checked the full marker set) and both runners now check it. Deliberate
  limits: a runner accepts as soon as the completion marker appears, so a guest that prints the markers and then stalls
  is accepted (the guest does not power off), and the markers are plain text on the console, so a guest that prints all
  of them passes; the guest is trusted harness code. Linux profile: the only
  shared QEMU change since A0 is additive and used only by the disposable qualification guest (`QemuReferenceNetwork`,
  `QemuReferenceControl`, the `control` and `network` fields of `QemuAsterinasReference`, `run-linux.xsh --tap/--qmp`); no
  function that builds a profile's QEMU command line changed, `tests/system/qemu.xsh` passes 18 tests, and the Linux side
  of every cohort passed. Firecracker gets an API socket only when `LAPUTA_VMM_CONTROL` is set. No obsolete bypass code
  remains: the coldplug bypass went with A1 and a search of `guest/`, `infra/asterinas` and the docs finds no other. Host
  fixtures `tests/system/asterinas_host.sh` and `asterinas_protocol.xsh` pass.
- A6 native accounting, same method as A0 (15,255 identities, the A0 module order, 50-module batches, two-hour budget). The batched run used kernel `8708e64dc`, before the page-rounding fix; only the `test-gnu-cp` rerun used the final kernel `006f33dbc`.
  Full single-VM run (`XSH_TEST=all make asterinas-test`, 3000 s): the first run (kernel `69a647fc1`) ended after 1117 s with
  `Failed to allocate a large slot` for a 32 KiB kernel heap allocation (86 passed, 4 skipped); the guest reported 3.8 GB free
  throughout an instrumented rerun of the awk module (1734 s, no failure), so memory was not exhausted. Contiguous frame
  allocation reclaimed only the other CPUs' local pools, so chunks cached by the allocating CPU stayed unmerged with buddies in
  the global pool. The kernel now drains every CPU's pool (kernel test `reclaim_moves_chunks_cached_by_the_current_cpu_into_the_global_pool`
  fails without it). That this was the cause of the observed failure is not proven by a reproducer. The second full run
  (kernel `8708e64dc`) passed 108 cases, skipped 4 and met the 3000 s budget with no panic. Batched run, 10 batches
  (420 of 1,015 modules attempted, 595 unstarted): 4,847 passed, 534 failed, 257 skipped,
  9,617 unexecuted, 0 unknown (A0: 1,281, 71, 65, 13,838 with 200 modules attempted). The attempted counts are not like for
  like: the ten batches took 7,737 s (the budget limits when a batch may start, so the last one ended after it), where the
  A0 batches took 54 minutes, and A0's guests panicked after 10 to 13 minutes. Batches 4 and 5 ended in a kernel panic
  (`attempt to subtract with overflow`, frame allocator `chunk.rs:31`) in `test_gnu_cp_sparse_perf_log`, which copies a 1 TiB
  sparse file: with the global pool almost exhausted the pool balancer rounded the amount to move to zero pages. The kernel now
  moves nothing below a page (kernel test `plan_moves_nothing_when_the_global_pool_is_almost_exhausted` fails without it);
  `test-gnu-cp` then runs to completion on the final kernel (59 cases: 37 passed, 22 failed) and `sparse_perf` fails after
  20 s where Linux passes it. Those two batches' in-flight module is unexecuted. Comparison with A0: 1,267 of the 1,281 A0
  passes still pass. The 14 that do not are all `test-bb-awk` cases that fail with `process timed out` (5 s): the awk
  population that times out differs between runs (A0 33 cases, A6 43; 29 in both, 4 only at A0, 14 only at A6).
  Cause, established after A6: not a hang and not a kernel wait or wakeup defect. Each awk case starts the XSH interpreter on a
  225 KB `awk.xsh`, which costs about 1.5 s of CPU on Linux (user 1.5 s, sys 0.03 s, 45,000 page faults) and about 1.9 s on
  Asterinas (user 1.5 s, sys 0.2 to 0.3 s) against a literal `timeout: 5s` in the generated case. On this shared host the same
  guest work stretches 2.1 to 2.5 times in bursts that last tens of seconds, on Linux as well as Asterinas, and the case
  times out when the stretched time passes 5 s: Asterinas needs about a 2.5 times slowdown, Linux about 3.1 times.
  Measured, per-case durations of the 49 cases: A0 fan-out median 5.0 s (min 4.0), A6 fan-out median 5.1 s (min 4.3), with the host load
  not recorded; five later full-module runs on the unchanged kernel at lower load have medians 2.1
  to 2.9 s and 11, 0, 0, 9 and 1 timeouts, and the A0 pass-set rerun has median 2.1 s and 1 timeout; four paired runs with the
  Linux reference booted at the same time have Linux medians 1.6 to 1.9 s (max 3.9 s) and no timeout. Over the eight Asterinas
  runs of the module (A0, A6, six later) one case never timed out, none timed out every time (at most 4 of 8 runs), and 48 timed out at least
  once, so the failing cases follow the clock and not the case. Timelines of a paired run show Linux and Asterinas
  slowing together (Linux 1.6 to 3.3 s, Asterinas 2.0 to 5.1 s). No invocation hung: 133 awk invocations in guests with the
  same kernel all exited 0, the slowest after 18.0 s. With six busy loops pinned to the four cores that run the guests,
  16-iteration medians were 4.4 s and 3.9 s on Asterinas against 3.4 s and 3.0 s on Linux (quiet: 2.3 s and 1.8 s against
  1.8 s and 1.5 s), and Linux reached 6.9 s in one run. The kernel part is the anonymous
  page-fault path: a fault costs 3.4 us in the guest against 0.37 us on the Linux reference (probably huge pages; not checked), and `MAP_POPULATE` is ignored,
  which accounts for most of the 25 percent gap in the quiet case. The A6 frame
  allocator changes touch only the failure and balancing paths and not this path. The timeout stays 5 s. Consequently the 14
  are recorded as host-load flakes: the A0 pass-set rerun (125 modules with A0 passes, 3 batches, 907 s, host load 5 to 20)
  passes 1,313 cases and loses 1 of the 1,281 A0 passes, `test_bb_awk_awk_length_0`, a 5.1 s timeout in a module that
  passed 48 of 49 at that load; no other module lost a case. The accounting rule needs a stability criterion for
  timing-bound cases; that choice is open. Paired Linux run of the 131 modules with Asterinas failures plus
  `test-gnu-cp` (5 batches, all executed): of the 534 Asterinas failures, 171 pass on Linux (43 `test-bb-awk` timeouts, 24
  `test-uu-cp-3`, 12 `test-stty`, 12 `test-ss`, 10 `test-procps`, 6 `test-traceroute`, 6 `test-ionice`, 5 `test-tracepath`, and
  smaller groups), 361 fail on both (environment debt, including the root-user fixture mismatch) and 2 are skipped on
  Linux (534 = 171 + 361 + 2). Linux fails 24 cases that Asterinas did not fail: 19 of them are `test-gnu-cp` cases that
  Asterinas never ran in this accounting (its two batches ended in the panic), and 5 are xattr and ACL cases in
  `test-cp`, `test-uu-cp-4` and `test-setfacl`. The `test-gnu-cp` rerun on the final kernel ran all 59 cases and failed
  22: 19 fail on Linux too and 3 fail only on Asterinas (`cp_i`, `preserve_link`, `sparse_perf`), so
  `sparse_perf` is not the only Asterinas-only `test-gnu-cp` failure. 9,617 cases remain unexecuted baseline debt. No time gate was run in A6, so performance
  qualification stays open for A7.
  Contract changes: `qualify.sh` takes the cohorts `device`, `clock-abi`, `clock`, `recovery` and `all` and exports
  `ASTERINAS_EXTRA_PACKAGES=ntpd-rs` unless the caller sets it; `qualify-network-cohort.sh` became `qualify-cohort.sh`;
  `run-guest-case.sh` and `run-witness.sh` require the full guest marker set on both backends; the guest containers are
  named `laputa-asterinas-case-PID`. Kernel: the frame allocator reclaims the allocating CPU's pool and does not balance by
  less than a page. Not done: the independent completion review under `ultrareview`, which the coordinator runs next.
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

### A0 Asterinas-only native failures

Cases that failed on Asterinas and passed on the paired Linux run, with the
Asterinas failures confirmed only where the batch did not end in a panic. The
`test-bb-awk` entries are 5 s timeouts of CPU-bound cases whose set changes from
run to run (A6 native accounting), not a defect of those cases:

```text
core/tests/test-bb-awk.xsh::test_bb_awk_awk_F_case_7_f0745f82
core/tests/test-bb-awk.xsh::test_bb_awk_awk_F_handles_escapes_547f57da
core/tests/test-bb-awk.xsh::test_bb_awk_awk_NF_in_BEGIN_77c25514
core/tests/test-bb-awk.xsh::test_bb_awk_awk_backslash_newline_eaten_with_no_trace_68a9ed7c
core/tests/test-bb-awk.xsh::test_bb_awk_awk_cmd_getline_6bdf67c7
core/tests/test-bb-awk.xsh::test_bb_awk_awk_delete_a_v_evaluates_v_once_5f6b7a5d
core/tests/test-bb-awk.xsh::test_bb_awk_awk_do_not_allow_str_724d0fde
core/tests/test-bb-awk.xsh::test_bb_awk_awk_exit_N_propagates_through_END_s_exit_30365011
core/tests/test-bb-awk.xsh::test_bb_awk_awk_f_and_ARGC_005000c7
core/tests/test-bb-awk.xsh::test_bb_awk_awk_floating_const_with_leading_zeroes_74725453
core/tests/test-bb-awk.xsh::test_bb_awk_awk_handles_empty_function_f_360001dc
core/tests/test-bb-awk.xsh::test_bb_awk_awk_handles_empty_function_f_arg_9bb5221b
core/tests/test-bb-awk.xsh::test_bb_awk_awk_handles_whitespace_before_array_subscript_eb5ef338
core/tests/test-bb-awk.xsh::test_bb_awk_awk_hex_const_1_5430ac3b
core/tests/test-bb-awk.xsh::test_bb_awk_awk_hex_const_2_ee9196a0
core/tests/test-bb-awk.xsh::test_bb_awk_awk_if_length_0_dd284655
core/tests/test-bb-awk.xsh::test_bb_awk_awk_if_operator_3df55f1c
core/tests/test-bb-awk.xsh::test_bb_awk_awk_if_operator_de706398
core/tests/test-bb-awk.xsh::test_bb_awk_awk_if_operator_eb575c43
core/tests/test-bb-awk.xsh::test_bb_awk_awk_if_string_2a35cfdb
core/tests/test-bb-awk.xsh::test_bb_awk_awk_input_is_never_oct_308726e9
core/tests/test-bb-awk.xsh::test_bb_awk_awk_length_array_3f6ea1ee
core/tests/test-bb-awk.xsh::test_bb_awk_awk_printf_prints_one_e1cb147b
core/tests/test-btop-cli.xsh::test_btop_live_source_syscall_trace_has_no_child_process
core/tests/test-chrt.xsh::test_chrt_changes_the_policy_of_another_process
core/tests/test-chrt.xsh::test_chrt_runs_a_command_under_the_policy
core/tests/test-chrt.xsh::test_chrt_time_slice_reaches_the_fair_policies
core/tests/test-cp.xsh::test_cp_debug_reports_copy_policy_statuses
core/tests/test-cpio.xsh::test_cpio_sparse_extraction_and_symlink_targets
core/tests/test-date.xsh::test_date_format_modifiers_and_width_bounds
core/tests/test-dd.xsh::test_dd_sparse_copy_preserves_zero_file_as_a_hole
core/tests/test-dd.xsh::test_dd_sparse_copy_writes_data_after_a_hole_at_the_right_offset
```

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
