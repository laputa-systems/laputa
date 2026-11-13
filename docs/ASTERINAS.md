# Asterinas and Firecracker

The checked-in kernel pin is `81e2541ce`, with XSH `d7b4c9c85`, recorded with
the other inputs in `infra/asterinas/inputs.lock`; both are published.
The kernel repair preserves CPU affinity across fork and thread creation.
The focused developer build passes the fork, thread and exec regressions and
the eleven native fixture cases. Full current-pin qualification remains open.

The maintained cohorts below were qualified at kernel `d59567c40` by
`bash infra/asterinas/qualify.sh all --backend both`, which runs every cohort
below on Asterinas/Firecracker and on the Linux reference and requires
identical state transcripts. On 2026-11-12, clean Laputa `33bffe43d` passed
the fresh published-input check and every cohort with
`LAPUTA_RECOVERY_REPEATS=10 bash infra/asterinas/qualify.sh all --backend both`,
including all ten paired boot, restart and carrier recovery rounds. The Linux
reference can still fail the clock `pause` case on a loaded host, because its
QEMU peer then holds the guest for 12 to 13.5 s against a 5 s margin.
The [roadmap](ROADMAP.md) owns the successor kernel
slices and the [TODO queue](../TODO.md) owns the remaining compatibility
obligations.

## Maintained surface qualified at d59567c40

- Boot and numeric: the pinned PM root boots and passes the numeric native
  tests on both backends.
- Devices: block devices appear in the `block` class with `uevent`
  attributes, partitions, and device numbers that match Linux; the packaged
  `mdevd` and `mdevd-coldplug` coldplug at boot and after a daemon restart.
- Clock: `clock_settime`, `adjtimex`, and `clock_adjtime` make CLOCK_REALTIME
  settable and steerable. `STA_INS` and `STA_DEL` schedule a leap second at
  the next UTC day boundary, which CLOCK_REALTIME repeats or skips and which
  moves the TAI offset as Linux does. `ntpd-rs` converges from positive and
  negative offsets, frequency error, pause and resume, and a jump, and its
  `leap_update` accepts the leap status it reports.
- IPv4 state: netlink addresses, routes, rules, and route-netlink
  notifications, and the packaged `dhcpc` across acquire, renewal,
  reconfigure, NAK, restart, and carrier loss against a scripted server.
  Unresolved neighbors queue packets as Linux does. Links report their
  carrier, its transition counts and their frame counters, which `ifconfig`
  shows. Blackhole, unreachable, prohibit and throw routes install, survive
  link loss, and refuse lookups with Linux's errno. Local, broadcast, anycast
  and multicast routes install through a device with their type, scope and
  attributes, and the dump reports them as Linux does. `ip link set` brings a
  link up or down with `RTM_NEWLINK`, which matches Linux's lookup, errno
  and resulting state. Gateway variants, non-dump output route lookup and finite
  preferred/valid address lifetimes also match Linux: expiry removes the address
  and derived routes, and netmask changes retain the original deadlines.
- Logging: the packaged `syslogd` receives local datagrams with their sender
  credentials and reads `/dev/kmsg`, whose records, positioning and overrun
  follow Linux. The ring carries the kernel's own records down to info level,
  so `dmesg` shows them; `loglevel=` sets only what the console prints.
- Memory: allocation survives cross-CPU frame-pool fragmentation.
- Storage: a writable ext2 mount records the mount in the superblock, clears
  the clean-unmount flag and bumps the mount count before serving writes, and
  the final unmount flushes the volume and restores the state observed at
  mount, so an unchecked volume stays unchecked until an offline checker
  repairs it. `fsync` of file data and its directory survives a VMM kill, and
  a full volume reports `ENOSPC` without leaving the image inconsistent.
- Native suite: the final bundle's own `xsht test --list-json` discovers 15,649
  cases. The bounded 126-module A0 run has 1,330 passed, 29 failed, 49 skipped,
  14,241 unexecuted and zero unknown cases, with no interrupted batches. It
  preserves every original 1,281 pass and every later 1,326 pass by exact ID.
  All 29 failures belong to the original failed set. Four wget fixture cases
  were unexecuted in the later 25-failure receipt; they now fail because the
  minimal guest has no Perl. This is not a full native-suite pass.

Final receipts are retained under `.work/wt/final-asterinas/.work/tmp/`:
`published-inputs-d7.log`, `final-all-both-10.log`, `final-all-both-10.exit`,
`final-all-both-10.log.sha256`,
`a0-final/{original-accounting.log,slice5-accounting.log,final-preservation.json}`,
and `a0-final/results/accounting.json` (SHA-256
`e4ba100c6af14eb224972fbf70662a37a6f441ec8af98dbaf4eb96cf118b79dc`).
The standard bundle is `2ee696df0f743ecb67c408934d4091dd8ec1a747ec5b9db82bf6120e5e186dff`;
the corpus bundle is `1f409124d207e964689f312933b730a277206f95cb1718f95851a21b6f2a4930`.
Both use kernel ELF SHA-256
`7f5d46f1608ff5968eccaed8126ef2c1b8c0c12c1a96f6d66687f8608199c5a2`.
`final-ipv4-evidence/` retains the matching expiry, gateway and lookup
transcripts and both backends' raw logs.

IPv6 state remains deferred until a consumer needs it. Nonzero `RTA_IIF`
input-route queries are unsupported.

Known limits that no capability claims: a change to a link's name, hardware
address, MTU, queue length or link mode, or to any link flag other than
`IFF_UP`, fails with `EOPNOTSUPP`; traffic to the host's own non-loopback
address does not pass through `lo` or its counters; `MAP_POPULATE` is ignored,
which Linux permits; pipe ring buffers and large kernel heap allocations still
need contiguous frames; anonymous page faults cost about three times the Linux
reference.

The pinned kernel does not implement Landlock. `linux.run_confined` fails
closed there. PM therefore refuses a composition requesting a generated manual
index, which requires Landlock ABI 6. Roots without selected mandoc or manual
pages do not request that operation. See [the manual-index boundary](PM.md#root-composition).

The Asterinas backend uses the exact kernel, toolchain, Firecracker, and XSH
versions recorded in `infra/asterinas/inputs.lock`. Start on an x86-64 Linux
host with usable `/dev/kvm`; `infra/asterinas/preflight.sh` lists the required
host tools:

```bash
make asterinas-preflight
make asterinas-fetch
make asterinas-build
```

`asterinas-preflight` only checks the host and input declarations.
`asterinas-fetch` fetches the pinned Asterinas and XSH source and the declared
build inputs. It checks the kernel out with plain `git clone` and `git
checkout` (`infra/asterinas/checkout-kernel.sh`), so it does not need
`git submodule`, and the stamp that records fetched Cargo inputs depends on the
lock files' contents only, so a checkout elsewhere reuses a fetched cache. `asterinas-build` builds or reuses the Asterinas PVH kernel and
the Laputa generation, then publishes a content-addressed bundle. Changes in
the sibling XSH working tree do not affect this pinned build.

The Asterinas Cargo configuration uses the mycrates archive and native
registry. Its cached dependency set is bound to that configuration as well as
the kernel and toolchain lockfiles.

The XSH snapshot's source hash selects a Cargo target cache under
`.out/asterinas-firecracker/xsh-targets/`. `prepare-xsh.sh` points the shared
`.out/xsh-target` link at that cache, so host tools and the seed use the same
compiled inputs. A change of snapshot selects a different cache even when
Git archive timestamps precede the old build. An existing directory is
preserved under `xsh-targets/legacy.*`. Run
`bash infra/asterinas/test-xsh-target.sh` to verify that a source switch with
preserved timestamps changes the compiled program and that switching back
reuses the original binary.

The kernel, verified bundles, runtime disk copies, Firecracker configuration,
and logs live under `.out/asterinas-firecracker/`; fetched Asterinas and XSH
repositories under `.cache/asterinas/`. `asterinas-clean` runs `make distclean`
and removes the pinned `xsh-test` and Asterinas dev images, so the next build
is cold; tracked source checkouts stay. `asterinas-setup` builds the kernel and
boots a small kernel/VMM smoke guest.

Run the automated guest proof with:

```bash
make asterinas-test
```

The target uses PM to plan, build, and compose `baselayout`, `xsh`, `laputa-pm`,
and `xinit` into an immutable generation, creates and checks an ext2 image, and
boots that image as a Firecracker virtio block device. A small static initramfs
bootstrap mounts the device and pseudo-filesystems, chroots to the generated
root, and execs packaged `/init`; packaged xinit then runs as PID 1. Guest
checks exercise XSH, core commands, PM metadata, process behavior, and ext2
filesystem operations. Firecracker receives a writable per-run copy of the
verified bundle image. The serial log and result metadata remain under
`.out/asterinas-firecracker/`; test and interactive boot have separate
`test-console.log` and `boot-console.log` files.

The maintained viability root is minimal and runs selected tests as root.
It lacks the shell, Perl and compiler fixtures required by the full corpus.
Its `XSH_TEST` results establish bounded compatibility, rather than full native
qualification. Use the separate fixture below for that work.

Run one native XSH test module from the pinned XSH snapshot (paths are relative
to the XSH repository root) inside the guest with
`XSH_TEST=tests/xsh/stdlib/numeric.xsh`. A module under `core/tests`,
`dev/tests`, or `showcase/tests` can be selected the same way. Use
`XSH_TEST=core/tests/test-awk.xsh::test_awk_matrix_arrays_and_functions` to
run one exact test. Separate several selections with spaces to run them in
one guest, for example `XSH_TEST="core/tests/test-b2sum.xsh core/tests/test-base32.xsh"`;
the run budget is 300 s per selection, up to the 3000 s full-suite budget. Use `XSH_TEST=all` to run the full
native suite in a 2-vCPU guest configured by the pinned `xsht-config.ini`, including `core/tests`,
`dev/tests`, `tests`, and `showcase/tests`. The test source tree is staged from
the locked Git archive through a PM generation overlay; its digest is included
in the immutable bundle manifest. The selection is not part of the generation or
bundle: the host writes it into the disposable root copy before boot, so
changing the selection reuses the built bundle. Guest test runs use 4 GiB of
memory; the base viability proof uses 1 GiB. The selected tests run under the
packaged `xsht` without fail-fast, so one failure does not hide later cases, and
stream their results to the guest console. A failed selection is reported after
every selection has run. The host requires the guest success marker. To test a different
XSH source revision, update the XSH commit pin in `infra/asterinas/inputs.lock`
first.

### Full native qualification fixture

`infra/asterinas/build-native-fixture.sh` creates a separate 8 GiB ext2 image
from an immutable `Dockerfile.test` image, a clean XSH checkout and matching
verification products. It preserves the test image's Bash, Perl, compiler and
helper environment. The fixture runs tests as UID and GID 1000, with cleared
supplementary groups and one test worker. Root-only cases need their own cohort.
The fixture is not a PM generation or a maintained Laputa boot proof.

Prepare the verification products in the pinned Linux container, then run:

```bash
bash infra/asterinas/build-native-fixture.sh \
  /absolute/path/to/xsh \
  /absolute/path/to/xsh/target/linux-test/x86_64-unknown-linux-musl/verification \
  "$(docker image inspect --format '{{.Id}}' xsh-test)" \
  "$PWD/.work/tmp/native-fixture"
```

The output must not already exist. `fixture.json` identifies the image, XSH
commit, product hashes, init script and root-image hash. Keep the base image
read-only. Copy it into each run's private directory, make that copy writable,
and point a private Firecracker configuration at it. Never reuse the maintained
bundle's shared writable drive path for a native fixture.

The default `/etc/xsh-native.selection` contains `all`. For a bounded probe,
replace that file in the private image with exact IDs, one per line, using
`debugfs`. Read it back and compare it with the requested list before boot.
The guest executes every selection, rejects empty selections and reports failure
if any test command fails or discovers no tests. Per-test timeouts stay unchanged.

Pass `native-xsh` as the seventh argument to `infra/asterinas/run-test-vm.sh`.
For a matched Linux guest, use `infra/asterinas/run-native-linux.xsh` with the
Linux reference kernel, initramfs, private disk, console path, QEMU log path and
timeout in seconds. It uses the existing QEMU supervisor with the explicit
`NativeXsh` proof contract. The default contract remains the maintained Laputa
proof. Each contract rejects the other contract's completion marker.

The native protocol reports `XSH_NATIVE_CONTEXT`, `XSH_NATIVE_START` and
`XSH_NATIVE_RESULT`. Preserve those consoles, the requested selections and
`fixture.json` alongside the result. A passing bounded probe does not establish
full-corpus qualification or preserve an earlier bundle's pass set by itself.
If XSHT reports that its native process requires shutdown after failed
cancellation, the runner fails and reaps the VMM immediately. Record the
interrupted ID before accounting. The fatal report is not a completed test.

On 2026-11-12, XSH `9ba05675c` with the pinned test image and kernel
`d59567c40` runs the eleven formerly shared minimal-guest failures in this
fixture. All eleven pass on Linux. Asterinas passes ten and fails the taskset
affinity case: a later query observes mask `3` after setting mask `1`.
Kernel `81e2541ce` fixes this defect by copying the caller's affinity into cloned
user tasks. Its new regression fails fork and thread inheritance on `d59567c40`
while exec passes. The patched developer kernel passes all three paths and all
eleven native cases. The clean standard build of the published pin also passes
those fourteen probes. Its kernel ELF SHA-256 is
`dd5db1b9405497fd36905d69f75f13849fc9f20cee24ed9f7837adb9dbc826ee`.
The synthetic C witness IDs are separate from the 15,649 native IDs.

Full native execution stopped in
`.work/tmp/native-full-81e2541ce-9ba05675c/`, whose `run.json` fixes the kernel,
fixture and product identities. The private VM has two CPUs, 4 GiB RAM and the
unprivileged test principal above. It completed 1,034 passes, six failures and
five skips; 14,604 IDs remain unexecuted, with no unknown IDs. The btop headless
syscall-trace case exceeded its original 120-second deadline and failed bounded
cancellation after six more seconds. XSHT required process shutdown; the VMM
was then stopped and reaped.

All six completed failures reproduce independently. Four arise from tmpfs
ignoring root mode and ownership options, leaving `mode=1777` scratch mounts
root-owned and 0755. Published kernel `8a4449950` fixes those attributes and keeps
the internal ramfs, devtmpfs and memfd roots unchanged. Its new C regression
fails on `81e2541ce` and passes on Linux and the patched developer kernel. That
kernel passes the four affected native IDs and two independent native tmpfs
permission probes. Two du failures instead assume file allocation equals its
logical length. XSH `0b919a035` corrects those expectations and passes both IDs
in the patched guest. Developer evidence is in
`.work/tmp/tmpfs-root-options-after/`. The clean standard build passes the mount
regression, existing memfd and devtmpfs regressions, all six du cases, the four
permission failures and both synthetic permission probes. Evidence is in
`.work/tmp/tmpfs-clean-pin-proof/`. Its kernel ELF SHA-256 is
`b1e91aa376f23149d1aea6b9de9f5c095dcab31c0bc3d2d2b9eec1b05d0e6a79`.
Synthetic probe IDs remain separate from the 15,649-ID corpus.

Later XSH test and dd repairs need separate coverage because the full-run
fixture remains frozen at `9ba05675c`. Full native completion and maintained
cohort replay on the new pin remain open. Always copy a read-only base into a
fresh writable disk for each probe; a failed guest may not have synced its disk.

Published kernel `ba0383234` fixes the tracing deadlock. `PTRACE_TRACEME` held
the child parent lock while Yama's unprivileged ancestry check reacquired it.
The fix retains the parent thread reference and drops the lock before the
unchanged permission checks. The new unprivileged fork, exec and syscall-trace
regression fails on `8a4449950` and passes on Linux and the patched kernel.
The clean standard build passes that regression and both btop syscall-trace
cases at `.work/tmp/ptrace-clean-pin-proof/`. Its kernel ELF SHA-256 is
`d82a2bd4a409a383b251ac2dda2793a16d35c8384d0212a6f96d88878c918e43`.

The full run at `.work/tmp/native-full-ba0383234-3f4687802/` passes both btop
tracing cases, then stops at a cp fixture cleanup failure. Its accounting has
1,371 passes, three failures, twenty skips and 14,255 unexecuted IDs. Cat fails
to reject copying onto its output. Chgrp and chown incorrectly allow changing
ownership to root as an unprivileged user.

Published successor `f296506e6` validates ownership changes against filesystem
credentials and `CAP_CHOWN`, before either requested ID changes. A per-inode
lock serializes ownership checks and mutations. Its 54-case regression covers
six syscall routes and passes on Linux, fails on `ba0383234`, and passes on the
repaired kernel on tmpfs and ext2. Both native ownership modules pass. The cp
parent-metadata case also completes cleanup.

Published kernel `5303dc23a` additionally returns `EINVAL` for non-symlink
`readlink` requests. The old default `EISDIR` aborts musl canonicalization through
procfs and prevents cat from identifying its output. Its syscall regression
fails before the repair and passes afterward. All 22 cat, readlink and realpath
native cases pass. The supporting commit message incorrectly says 25.

The clean standard build passes both syscall regressions and 48 native cases,
with three expected privilege skips. Published-input and host checks pass.
Evidence is at the main checkout's `.work/tmp/ownership-readlink-clean-proof/`.
The kernel ELF SHA-256 is
`779f0e4f8e93b7d7dc00b965eeb3e24de37e88e10dc44e6a9eee2c9e07567d73`.
The wider cp module still fails its POSIX ACL xattr fixture. These focused
results do not establish full native or maintained-cohort qualification.

Failure discovery continues at the main checkout's
`.work/tmp/native-remaining-5303dc23a-3f4687802/` with the unchanged XSH
`3f4687802` fixture. Its 14,259 selected IDs include every unexecuted ID,
the three failed IDs and the cp cleanup case. It preserves UID/GID 1000,
cleared groups, one worker, two CPUs, 4 GiB RAM and original test deadlines.
Keep its private writable disk while the VMM runs. A final full qualification
at the candidate pin remains open.

To run a kernel regression witness against the built bundle and against the
Linux reference with the same memory, run
`bash infra/asterinas/run-witness.sh asterinas|linux SOURCE.c DIR` on a C file
under `asterinas/test/initramfs/src/regression`. The runner compiles it
statically in the pinned development image, places it in the disposable root
copy, and requires the guest's witness start and finish markers. A kernel panic,
heap allocation error, or nonzero witness exit fails the run.

Run the kernel unit tests of one pinned-source crate with
`bash infra/asterinas/run-ktest.sh ostd`,
`bash infra/asterinas/run-ktest.sh osdk/deps/frame-allocator` or
`bash infra/asterinas/run-ktest.sh kernel/core` (the kernel crate itself). The
runner boots the OSDK test kernel in QEMU with KVM and two CPUs, and fails
unless every test passes. It needs a prior `make asterinas-build` for the OSDK
install. The kernel crate links `aster-cmdline`, which leaves the serial console
off unless the command line has `earlycon`, so the workspace `OSDK.toml` passes
`earlycon` to test kernels; without it the kernel crate's tests run silent and
the runner rejects them.

To run a guest case (a script and its helper programs) on either backend, run
`bash infra/asterinas/run-guest-case.sh asterinas|linux CASE_DIR MODE RESULT_DIR`.
The runner compiles each `.c` file in the case directory, places the files under
`/usr/lib/asterinas/case`, and requires the guest's case start and finish
markers. `ASTERINAS_EXTRA_PACKAGES="ntpd-rs"` adds packages to the generation
for a build. With `LAPUTA_GUEST_NETWORK=tap` an Asterinas case runs inside a disposable
container network namespace with an owned TAP device `tap0` (192.0.2.1/24) wired to a
virtio-net device `eth0`; nothing on the host network changes. The Linux reference
guest gets the same TAP and a `virtio-net-pci` device when `LAPUTA_GUEST_NETWORK=tap`
(QEMU runs in an equivalent container). `ntpd-rs` also needs the operator-provisioned, git-ignored
`packages/ca-certificates/files/trust-update-key`; a worktree build must copy it
from the main checkout, because worktrees do not carry ignored files.

Run the IPv4 state operations cohort with
`bash infra/asterinas/qualify.sh network-state --backend both [--case NAME]`.
It builds and runs each netlink witness of the cohort on both backends, then runs
the `guest/asterinas/network-state` case in each mode (`loopback`, `link`,
`netlink-link`, `address`, `route`, `events`, `packet` and `ioctl-config`) against a
TAP-backed `eth0` and requires the two `NET_` transcripts to be identical. `link`
changes link state with `SIOCSIFFLAGS` and `netlink-link` with the packaged
`ip link set`, which sends `RTM_NEWLINK`. `route_types` installs local, broadcast,
anycast and multicast routes through `lo`, compares each route's type, scope,
protocol, table, flags and attribute order with Linux's, and compares the errno
of a scope that is too wide, a missing device, an unknown device and an unknown
type. Its gateway matrix compares those four types at global, link, host and
nowhere scope, with an explicit, inferred or missing interface. Local routes
refuse gateways. Broadcast and anycast routes accept gateways at link scope,
and multicast routes accept them at global and link scope.

`route_lookup` compares IPv4 output queries without a dump, including source,
output interface, mark, uid, and `RTM_F_FIB_MATCH`. The witness checks each
route type, rejection errno, attribute order, explicit-interface direct paths,
and missing or down devices. Broadcast sources fail with `ENETUNREACH`.
`RTM_F_FIB_MATCH` requires a stored route even when an explicit interface
permits a direct output path. Cache length, error and expiration are compared.
Cache use counts and ages are per-query state and are omitted from the
transcript. Nonzero `RTA_IIF` input-route queries remain unsupported.

`addr_config` compares finite preferred and valid IPv4 lifetimes. Deprecation
emits `RTM_NEWADDR`, and expiration emits `RTM_DELADDR`, removes derived routes
and prevents a new bind. Removing an address cancels its old expiry, and a
netmask change preserves its remaining lifetime and deprecated state.
Interface address labels such as `lo:expiry` resolve to their base device for
ifreq ioctls. As on Linux, infinite validity makes an address permanent and
reports both lifetimes as forever. A zero preferred lifetime still sets the
deprecated flag. Invalid lifetime pairs fail with `EINVAL`.

`events` also compares the route-netlink notifications. `ioctl-config` configures the address and netmask with
`SIOCSIFADDR` and `SIOCSIFNETMASK` through XSH's guarded `linux.ioctl`, and adds and
removes the gateway and network routes with `SIOCADDRT` and `SIOCDELRT` through the
case's `ioctl-route-probe` C helper (the guard's catalogue admits only ifreq-shaped
requests, so it cannot carry a `struct rtentry`). Besides the resulting address and
route dumps, it compares the errno of each failure: `ENODEV` for an unknown interface,
`EINVAL` for a non-`AF_INET` ifreq and a non-contiguous netmask, `EEXIST` for a
duplicate route, `ESRCH` for deleting a route that does not exist, and
`EAFNOSUPPORT` for a route destination that is not IPv4. Two normalizations apply:
the Linux reference has a `sit0` link, which the case omits, and IPv6 is outside the
cohort (the reference kernel has no IPv6 policy routing and adds link-local addresses),
so IPv6 address, route and rule lines are not compared.
The cohort uses whichever bundle `make asterinas-build` last selected.

Run the DHCP cohort with `bash infra/asterinas/qualify.sh network --backend both [--case NAME]`.
It runs the `proc_boot_id` and `udp_device` witnesses, then each mode of `guest/asterinas/dhcp`
(`lease-acquire`, `lifecycle`, `renewal`, `reconfigure`, `nak`, `restart`, `carrier`, `tcp`,
`reject-routes`, `syslog`) against the same
TAP-backed `eth0`. The container end of the TAP runs the XSH pin's scripted DHCP server
(and, for `tcp`, a C payload server) from the case's `peer.sh`; the guest runs the packaged `dhcpc`.
`carrier` also compares, at every step of its link cycles, `IFLA_CARRIER`, the carrier
change, up and down counts, the size and error and carrier counters of `IFLA_STATS64`
and `IFLA_STATS` on `lo` and `eth0`, whether `eth0` counted frames in both directions, and
the `TX errors` line of the packaged `ifconfig eth0`. Frame counts themselves differ between
the kernels and are not compared. `reject-routes` installs one foreign route of each type,
keeps them across a link cycle while `dhcpc` rebinds, connects UDP sockets through them
(`EINVAL`, `EHOSTUNREACH`, `EACCES`, and a throw that falls through to the `default`
table), and compares the errno of each invalid request and of the removals. `syslog`
compares `/dev/kmsg` records, priorities, escaping, the 1024-byte write limit, short-buffer,
end-of-ring, seek and overrun errors, then runs the packaged `syslogd --kmsg /dev/kmsg`
with the case's `syslog-client` C program and one kernel-ring record, and compares the
records it writes apart from times, sequence numbers and process ids.
The `NET_` transcripts of the two kernels must match. A mode takes 40 to 80 s per backend.

Run the ext2 storage cohort with
`bash infra/asterinas/qualify.sh storage --backend both [--case dirty|full|unclean|corrupt]`.
It creates disposable 4096-byte-block ext2 images and runs the
`regression/storage/qualify` witness on both backends. `dirty` writes and
fsyncs a known payload, then the VMM is killed while the guest extends a churn
file; `full` fills the volume until `write` returns `ENOSPC` and unmounts;
`unclean` syncs the payload and is killed without an unmount, leaving a
consistent volume whose clean flag is clear; `corrupt` cleanly prepares a
payload image, then replaces the primary group descriptor's inode-bitmap
pointer on a disposable copy and requires both guests to refuse a writable
mount without changing the image. The host classifies every image with
`e2fsck -fn`, then `e2fsck -fy` on a fresh copy when the first pass reports
errors: exit 0 is clean, 1 or 2 is repaired, and anything else is
unrecoverable. A dirty image that is unrecoverable fails the cohort, as does a
corrupt image that e2fsck calls clean. Every clean or repaired result is
booted again on the same backend, which re-reads the payload hash and mode,
writes one verification file, and unmounts; the host then requires a clean
`e2fsck -fn`, the same clean-unmount flag the image had at mount, and an
incremented mount count. The two backends must produce identical `STORAGE_`
guest transcripts. Two fields are normalized because the Linux reference
mounts through the ext4 driver's ext2 mode: the exact `STORAGE_FULL_DONE` byte
count, since a write that cannot cover its whole range is rolled back by the
Asterinas ext2 driver but completed partially by ext4, and the
`STORAGE_CORRUPT_REFUSED` errno, where ext4 returns `EUCLEAN` and Asterinas
returns `EIO` before its descriptor-range check. Both backends still have to
report `ENOSPC`, refuse the corrupt mount, leave the corrupt image byte for
byte unchanged, and pass the same classification.

The remaining cohorts run the same way. `device` runs the baseline boot proof, whose
guest coldplugs three times and after a daemon restart, the `device/block_uevent`, `device/kmsg` and `fs/sync/writeback` witnesses and
the modes of `guest/asterinas/device`: `sysfs`, `add` and `nodes` compare the device paths,
uevent data, synthetic add events and coldplugged node ownership of two disks, their partitions
and the memory devices with the Linux reference (the case ships `data-disk.sh`, which makes the
second disk both guests attach), and `missing` is a negative control that must fail with a
missing add event on both backends. `clock-abi` runs the `time/clock_adjust` witness. `clock` runs the
`network/udp_ancillary` witness and the `guest/asterinas/clock` case in the modes
`behind`, `ahead`, `frequency`, `pause` and `jump` (the last two on a TAP-backed network
with an outside peer). `recovery` repeats the boot proof and the DHCP `restart` and
`carrier` modes `LAPUTA_RECOVERY_REPEATS` times (3 by default; set 10 when a change touches boot, DHCP or the recovery path). `all` runs `baseline`,
`device`, `clock-abi`, `clock`, `network-state`, `network`, `storage` and `recovery` serially and
exits nonzero if any cohort failed. The wrapper exports `ASTERINAS_EXTRA_PACKAGES=ntpd-rs`
unless the caller sets it, because the clock cases need the daemon in the generation and a
bundle built without it would replace the current one. A cohort names each case it passes
and fails when it ran none.

Account for the cost of the paired boot and numeric guests with
`bash infra/asterinas/qualify.sh resources --backend both [--case boot|numeric]`. It runs the
baseline case on each backend while sampling the VMM process (`firecracker` or `qemu-system-x86_64`)
every 50 ms, and prints one `resources:` line per backend and case: the kernel, initramfs and root
image sizes in bytes (Asterinas from the selected bundle, the Linux reference from its package;
the root is the same ext2 image, apparent and allocated), the guest memory read from the VMM's own
command line or configuration, the VMM's peak resident set (`VmHWM`) and, between a successful
`perf-gate-ready` and a successful `perf-gate-ready -1`, the VMM's user and system CPU time (all
threads, including guest execution, until the VMM exits after the guest powers off). Sizes and memory are
measured on every run. When either gate check fails the CPU time is printed as `cpu=deferred`
and the cohort ends with `perf gate deferred: host busy`; a run is never repeated until a gate
passes. The cohort fails when it observes no VMM process.

`run-guest-case.sh` and `run-witness.sh` accept a run only when the case or witness marker
is present, the exit status is zero, the complete guest marker set is present and the guest
powers off, on both backends. The viability profile runs its boot proof as a `sysinit` entry and ends the
inittab with a `poweroff` entry that exits at once, so xinit powers the guest off when the proof
has finished. The proof keeps the console it inherits. As the `poweroff` entry it ran on its own terminal
session, and one of 19 carrier runs on the Linux reference ended with the proof's output cut off mid-line and
the guest powered off before the completion marker; the cause was not established, and the `sysinit` form
is the one that every earlier run used. Linux powers off through ACPI
(the reference kernel package must be built from a Linux recipe that keeps the legacy ACPI power
path, or its guest halts with QEMU still running), and Asterinas writes QEMU's debug-exit device,
then the ACPI soft-off of the q35 machine and then the keyboard controller's reset, which ends a
Firecracker VM. After the completion marker the runner gives the VMM `LAPUTA_POWEROFF_POLLS`
polls of 0.2 s (300 by default) for Firecracker and 60 s for QEMU to exit with status zero, and
rejects a VMM that stays up, exits with another status or reports a kernel failure meanwhile.
A guest that stalls before the marker is rejected after its timeout. SIGTERM or SIGINT to a
runner, to `qualify-cohort.sh` or to `qualify.sh`, including one nested inside another,
stops the owned guests, removes the owned container (named `laputa-asterinas-case-PID`, with
its TAP and peer processes) and removes the cohort's results. A runner gives its child
`LAPUTA_CANCEL_GRACE_SECONDS` (20 by default) to stop after SIGTERM before it kills it, and
passes three seconds less to the child's own runners, so an outer runner never kills one that is
still cleaning up. A cohort runs its backends one after the other.

Check that the pins are public with `bash infra/asterinas/qualify.sh published-inputs --backend asterinas`.
It fetches the kernel commit and the XSH commit named in `infra/asterinas/inputs.lock` from the lock's
repositories into fresh bare caches under `.work/tmp`, requires each fetch to return exactly the locked
commit, and compares the kernel commit with the `asterinas` gitlink and the kernel's dev image version
with the lock's. A repository that answers but does not hold the commit fails, so a kernel commit that
exists only locally is red until the fork publishes it. The caches are removed on exit.

To account for many modules, run
`bash infra/asterinas/native-batches.sh asterinas MODULES BATCH_SIZE BUDGET_SECONDS DIR`
(or `linux`) on a list of test modules or exact test IDs, then
`bash infra/asterinas/account-native.sh DISCOVERED_IDS.json DIR [--baseline ACCOUNTING.json]`.
Each batch boots one guest from the built bundle. A guest that dies mid-batch
returns its in-flight module to the pending list once and records it as
interrupted if it dies alone. Modules left when the budget ends are written to
`unstarted.txt`; the accounting counts their cases and those of interrupted
modules as unexecuted. An interrupted exact selection excludes only that ID;
other completed IDs in the same module retain their results. The accounting exits nonzero when it finds no results, a
result for an undiscovered case, or a baseline case that no longer passes.
Its successful exit establishes accounting and pass preservation. Full native
qualification additionally requires no failed, unexecuted, unknown or
interrupted cases, with every skip assigned to its fixture or platform owner.
Run the accounting regression checks independently with
`bash tests/system/asterinas_native_accounting.sh`; the host checks also run them.
To compare against the original A0 pass set, use
`bash infra/asterinas/account-native.sh DISCOVERED_IDS.json DIR --baseline infra/asterinas/a0-baseline.json`.
Discover the identities from the corpus the bundle carries: extract
`git archive HEAD` of the XSH snapshot under
`.out/asterinas-firecracker/xsh-snapshots/` and run `xsht test --list-json`
there. A list discovered from an older XSH lacks the pin's newer cases, so the
accounting reports them as unknown and fails.

Native cases carry fixed timeouts that the guest must meet on a shared host. The
`test-bb-awk` cases need about 1.9 s on Asterinas and 1.5 s on the Linux reference
against a 5 s limit, and a loaded host stretches both by 2 to 2.5 times, so a busy
fan-out reports `process timed out` for cases that are not hung. Each batch console
log prints the duration of every case: a run whose passing awk cases take more than
about 3 s ran on a loaded host, and its timeouts are not evidence of a kernel
defect.

For the paired boot and numeric pilot, provide a Laputa x86_64 Linux package
archive with built-in virtio and ext2 support:

```bash
LAPUTA_LINUX_KERNEL_PACKAGE=/absolute/path/to/linux-package.tar.gz \
  bash infra/asterinas/qualify.sh baseline --backend both
```

The runner copies the same verified PM root to each guest. Linux uses a
disposable initramfs that initializes loopback. `--backend linux` or
`--backend asterinas` selects one guest. `--case boot` or `--case numeric`
selects one case. The default Linux package path is
`.out/asterinas-firecracker/linux-package.tar.gz`. The pilot does not account
for the full native suite; the cohorts above each qualify only the cases they list.

Laputa keeps its Asterinas compatibility work in the `asterinas/` submodule,
which points at the pinned fork in `infra/asterinas/inputs.lock`. Missing
syscalls required by Laputa, XSH, or a selected guest test belong in that fork
with kernel regression coverage; do not work around them in userspace or skip
the exposing test. For a fingerprinted build of uncommitted local kernel edits,
run `ASTERINAS_LOCAL=1 make asterinas-test`. Commit a kernel change and update
the lock and submodule gitlink together before using the clean pinned workflow.

For an interactive session, run:

```bash
make asterinas-boot
```

The shell uses the pinned XSH commit. Type `laputa-exit` in the guest to stop
Firecracker; Ctrl-C interrupts xshi. `asterinas-shell` and `asterinas-viability` are legacy aliases
for `asterinas-boot` and `asterinas-test`.

