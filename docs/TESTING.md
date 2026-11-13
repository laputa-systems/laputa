# Testing

Set up the host tools as described in [development](DEVELOPMENT.md#xsh-tools).
The examples below use its `XSHT` environment variable.

```bash
make check         # xsht check over the tree, plus shebang-only XSH scripts
make lint          # production PM, system, installer, and xinit modules
$XSHT lint         # the full configured tree, including recipes and tests
make test-pm
make test-system   # tests/system, then tests/integration
make test-xinit
make test-linux    # the kernel recipe's Kbuild tests and linux-headers' headers_install tests
make test          # all four
make test-components-integration # distribution suites and the canonical guest profile
```

Kbuild planner tests cover object-list replacement, nested `patsubst` and
`foreach` expansion, conditional defaults for defined empty flags, and
`cc-option`/`cc-disable-warning` calls, which are probed with the target
compiler when archive tasks are planned. Planning fails on any compile
argument that still contains `$(`. These fixtures do not qualify a complete kernel build.

`xsht-config.ini` sets `module_path` to this checkout, so `xsht` resolves
`system.*`, `seed.*`, and PM imports, including `use` imports inside profiles
loaded through `module.load`. It excludes the fixture trees under
`tests/*/fixtures/` and `mirror/`. `make check` also checks the XSH programs
installed under other names (installer and profile boot hooks, baselayout's
`getent`), which xsht's `*.xsh` scan does not find; it finds them by their
`#!/bin/xsh` shebang.

Narrow before widening: `xsht check` on the changed modules, then the focused
suite (`$XSHT test tests/pm/pm_plan.xsh`), then the Docker builds, and QEMU
last. Run one suite at a time. `make test-pm-docker` runs the whole PM suite
inside package-tools with the seed, offline; `make test-pm-native` runs it
against `XSH_ROOT`'s debug build with coverage.

`tests/integration/cross_consumer.xsh` imports PM and the profile modules
together. Check and run it on its own to tell PM-owned diagnostics from
profile-owned ones:

```bash
$XSHT check tests/integration/cross_consumer.xsh
$XSHT test --jobs 1 tests/integration/cross_consumer.xsh
```

Component Cargo suites, Rust lints, protocol goldens, and component-only VM
harnesses belong in their upstream repositories. This repository verifies
checksum-pinned package sources, artifact constraints, supervisor policy,
and installed guest behavior. Land shared component changes upstream before
updating recipe pins.

`make test-components-integration` runs `make test` and the canonical Ghostty
profile. The profile needs the infrastructure described in [QEMU](QEMU.md)
and [Tinyland](TINYLAND.md). This distribution integration gate is separate
from `make verify`.

Use `cargo -j 4` for Rust checks. `make mirror-test` checks the mirror and its
POSIX deployment scripts; on Linux it runs Cargo offline in `xsh-test`.
`make verify` is the full host proof from a clean build, with logs and a timing
table under `.out/verify/`; reserve it for an explicit full verification run.

The aarch64 world rebuild and boot proofs are unverified; see [TODO](../TODO.md).

The standalone Linux x86_64 Docker authority check uses a local image with
an existing `/bin` and `/usr/lib/xsh/core`, plus a native static XSH seed
directory containing `xsh`, `xshi`, `xsht`, and `core/`:

```bash
TMPDIR="$PWD/.work/tmp" "$XSH_HOST" tests/docker/profile_network.xsh -- xsh-test:latest "$PWD/.out/seed/x86_64"
```

Create `.work/tmp` before running the check. The image is an explicit trusted
test substrate; the check does not fetch or build package-tools. A bridged
control must accept a UDP route lookup without sending packets. The profile
adapter must reject the same lookup with `ENETUNREACH` under `--network none`.
The check also verifies that host poison variables stay outside the container,
host sentinels survive, the checkout mount rejects writes, and `/output` remains
writable. It does not qualify C, Rust, or XSH package builds or a per-package
input closure. The default native suites do not require Docker for this check.

The clock-service privilege boundary can be checked without changing the host
clock. This uses a fake daemon in a disposable Docker container and requires
Docker to grant `CAP_SYS_TIME`:

```bash
bash tests/docker/ntpd_privileges.sh laputa-package-tools:TAG "$PWD/.out/seed/x86_64"
```

It checks the launched identity and capability sets and refuses a conflicting
UID before changing the runtime directory. It does not qualify clock steering.

### Run the DHCP lifecycle proof

`python3 tests/integration/dhcp_lifecycle.py` needs the built `qemu-maintained` image and
KVM. It owns one unprivileged user and network namespace, a tap, a scripted DHCPv4/DNS
server, and a virtio-serial control agent installed only on the disposable state disk, so
lease expiry and link loss never cut the control channel. Pass `--xsh` and `--core` for
the seed that built the image. It walks renewal, rebind, NAK, expiry, restart, link loss,
NIC reappearance, and pause/resume, then boots offline.

### Run the SSH network-recovery proof

`python3 tests/integration/ssh_network_recovery.py` needs the same built image and
KVM, a seed `xsh` with the native SSH client, and `oxish-keygen` (pass
`--oxish-keygen`, or let it extract one from `--artifact-store`). It owns one
unprivileged user and network namespace, one tap, and a scripted DHCPv4 server
that declares `192.0.2.100/24` on the tap address `192.0.2.1`; the virtio-serial
control agent is installed only on the disposable state disk. Unlike the DHCP
lifecycle proof, administration travels over the network under test: XSH's
native SSH client connects to the declared address inside the namespace with
the OxiSH host key provisioned on the state disk. After link loss, lease
expiry and re-acquisition, a supervised `dhcp-eth0` restart, and NIC
reappearance on a new ifindex, the test requires a fresh verified connection to
recover on the declared address and reads `xinit status dhcp-eth0` over it.

The same run asserts the maintained profile's explicit IPv6 policy. The
packaged `/usr/lib/sysctl.d/20-ipv6.conf` disables IPv6 on `all` and `default`,
clears `accept_ra` and `autoconf`, and therefore keeps a re-enumerated interface
disabled; the control agent observes no IPv6 address and no IPv6 route
(`addresses=0 routes=0`), and the service status reports IPv6 as unsupported
rather than a silent empty cohort: `ipv6=unsupported disabled=1 policy=installed
sysctl=1 addresses=0 routes=0 enumerated=1`. Any other state is a failure. This
reports IPv6 as unsupported; it does not add IPv6 support.

### Run the maintained clock drill

`python3 tests/integration/maintained_ntp.py` needs the built `qemu-maintained` image,
KVM and outbound network access from the guest, and it never touches the host clock. The
state disk is seeded with the ca-certificates trust store (the image's `/etc` and `/var`
live on the state disk, so NTS has no roots without it). Boot one (`LAPUTA_NTP_DRILL=sync`)
checks that readiness reports stratum 16, that all three NTS operators answer with no
missed polls, that a SIGKILLed daemon restarts and resynchronizes, then reboots through PID 1.
Boot two (`offline`) resynchronizes after the reboot, inserts a rule with `nfcrt` that drops
UDP 123 and TCP 4460, and requires the daemon to stay alive and the wall clock minus the
monotonic clock to move less than 20 ms in 120 seconds with no logged jump. On 2026-11-01
the sync boot reached stratum 2 and the offline boot saw a one-millisecond change. The
drill uses real operators, so a failure can be an operator outage; rerun before concluding.

### Run the offline clock-readiness guest

`python3 tests/integration/maintained_ntp_offline.py` needs the built `qemu-maintained`
image and KVM but no outbound network. It owns a user and network namespace, a tap with no
DHCP server, and the DHCP lifecycle control agent, so the guest has `eth0` without an
address, default route or resolver and cannot reach any NTS-KE server. The disposable state
disk leaves `/var/lib/ntpd-rs` absent, as the maintained provisioning does, so the launcher
creates it with UID/GID 123 and mode 0700; a provisioner that pre-creates it with other
ownership is refused by design. The daemon must report `running`, `ready` with no restarts,
print stratum 16 through `ntp-ctl`, and keep the same process and readiness for 120 seconds.
Unlike the maintained clock drill, this never contacts a real operator.

### Run the disposable NTP guest

With the x86_64 seed, package-tools image and artifact closure already built,
run the controlled startup cases in both directions, the sub-second `slew` case and the
external-backstep case separately:

```bash
bash tests/integration/ntp-clock-guest.sh behind /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE
bash tests/integration/ntp-clock-guest.sh ahead /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE
bash tests/integration/ntp-clock-guest.sh jump /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE
bash tests/integration/ntp-clock-guest.sh pause /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE
bash tests/integration/ntp-clock-guest.sh nts /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE
bash tests/integration/ntp-clock-guest.sh frequency /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE
```

The runner needs writable KVM, host Rust and kache, `jaq`, and `mkfs.ext4`. It
builds a receipt-bound disposable profile under `.work/`, with two vCPUs and
4 GiB; it does not modify a shipped profile. The source uses a loopback server
whose time comes from `CLOCK_MONOTONIC_RAW`. The startup case requires a clock
step and supervisor restart. The jump case checks restart and source reselection;
it does not establish convergence after the jump. The pause case checks source
reselection after QMP stop and resume; its loopback source pauses with the guest.
The NTS case uses a test CA and local NTS-KE server, rejects tampered NTS
replies, and then requires authenticated clock convergence. The NTS fixture build
needs the locked Rust dependencies available offline. These cases do not
qualify external sources or the authenticated clock-floor policy. The bundled
NTS test certificate expires on 27 February 2027.

The slew case starts the guest clock 80 ms behind the controlled source, below the
step threshold, and requires convergence within 15 ms inside five minutes without
the daemon logging a jump and without any one 500 ms sample changing the offset by
30 ms or more. ntpd-rs corrects at roughly half a millisecond per second and
converged in about four minutes on 2026-11-01. The matching `chrony-slew` runner
(build chrony as described below) also converges without stepping the clock, but
corrects about 32 ms in a single sample; its rate is recorded and not bounded, so
the two daemons agree on the no-step outcome and differ in slew rate.

The frequency case uses a controlled source with a 100 ppm rate bias. It
requires a learned nonzero calibration, stops the source, and checks the
kernel frequency after a supervised restart. It then starts a fresh guest with
the same state disk, verifies that the kernel starts without the saved
correction, and checks restoration while unsynchronized before reselecting the
source. The frequency case also needs Linux musl GCC and mold for its read-only
kernel frequency probe. This checks a cold boot, not physical power-loss
durability or hardware-specific oscillator stability. The complete frequency
runner passed both boots on x86_64/KVM on 2026-11-01. Supply an artifact closure
that includes the current ntpd-rs package; the runner does not copy the host
source cache into its exported checkout.

To qualify a separately operated NTS server, use a hostname whose certificate
chains to the guest system trust store. The guest needs a plausible initial clock
for certificate validation and outbound DNS, TCP NTS-KE and UDP NTP access.
The external mode uses QEMU user networking and leaves the host clock untouched.
It requires synchronization with an NTS source, restarts the supervised daemon,
and requires NTS synchronization again. It does not compare clock accuracy to
an independent oracle. The endpoint receives real NTS and NTP requests.

```bash
bash tests/integration/ntp-clock-guest.sh external-nts /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE nts.example.org
```

The endpoint may include a port as `hostname:port`. On 2026-11-01, the x86_64
KVM guest selected `time.cloudflare.com` with NTS and stratum 4 before and after
supervised restart. The default controlled NTS case remains network-restricted
and uses its test CA.

For the optional chrony comparison, build the official chrony 4.9 source in
scratch using GCC targeting Linux musl, mold, and GNU make. The command below
uses the Alpine musl GCC toolchain and disables features outside the controlled
NTP comparison:

```bash
mkdir -p .work/tmp/chrony-oracle
curl -fsSL https://chrony-project.org/releases/chrony-4.9.tar.gz -o .work/tmp/chrony-oracle/chrony-4.9.tar.gz
printf '%s  %s\n' 4924c6f530105bcd5b9e9e33c48a2ae1bfd889222c8480bc41601110efc864d0 .work/tmp/chrony-oracle/chrony-4.9.tar.gz | sha256sum -c -
tar -xf .work/tmp/chrony-oracle/chrony-4.9.tar.gz -C .work/tmp/chrony-oracle
(cd .work/tmp/chrony-oracle/chrony-4.9 && CC='gcc -fuse-ld=mold' LDFLAGS=-static ./configure --disable-readline --disable-sechash --disable-nts --disable-refclock --disable-rtc --disable-privdrop --disable-timestamping --with-user=root && make -j2 chronyd chronyc)
bash tests/integration/ntp-clock-guest.sh chrony-behind /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE .work/tmp/chrony-oracle/chrony-4.9/chronyd .work/tmp/chrony-oracle/chrony-4.9/chronyc
bash tests/integration/ntp-clock-guest.sh chrony-ahead /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE .work/tmp/chrony-oracle/chrony-4.9/chronyd .work/tmp/chrony-oracle/chrony-4.9/chronyc
bash tests/integration/ntp-clock-guest.sh chrony-slew /absolute/path/to/xsh /absolute/path/to/seed /absolute/path/to/artifacts PACKAGE_TOOLS_IMAGE .work/tmp/chrony-oracle/chrony-4.9/chronyd .work/tmp/chrony-oracle/chrony-4.9/chronyc
```

Chrony uses `makestep 1.0 3` and the controlled source's two-second polling
interval. Each case checks readiness while unsynchronized, a clock step, and
convergence against `CLOCK_MONOTONIC_RAW`; it does not use chrony in a profile.

To renew the test-only localhost certificate, run from the repository root:

```bash
mkdir -p .work/tmp
work=$(mktemp -d "$PWD/.work/tmp/nts-cert.XXXXXXXX")
cp ntpd-rs/ntp-proto/test-keys/{gen-cert.sh,testca.pem,testca.key} "$work/"
(cd "$work" && sh gen-cert.sh localhost testca end)
cp "$work"/{end.key,end.pem,end.fullchain.pem} ntpd-rs/ntp-proto/test-keys/
```

### Run the VM storage publication fault cases

Use a built x86_64 self-hosting kernel and root disk with writable KVM on a
Linux x86_64 host. The runner needs `qemu-system-x86_64`, `mkfs.ext4`, and a
musl-linked `/sbin/e2fsck` with `libext2fs.so.2`, `libcom_err.so.2`,
`libblkid.so.1`, `libuuid.so.1`, `libe2p.so.2`, and `libeconf.so.0` in
`/usr/lib`. It copies the checker and libraries into the disposable input disk.

```bash
python3 tests/integration/storage_fault.py /absolute/path/to/vmlinuz /absolute/path/to/disk.img
```

The runner kills each owned QEMU after a selected publication point and boots
again to run `e2fsck` and read the record from the detached ext4 disk. The
x86_64/KVM run recovered `old` after staging, `old` after rename without a
directory fsync, and `new` after directory fsync. The unsynced rename accepts
either complete record. The recovery checker returned 1 in all three cases.
This fixture models a file publication; it does not call the activation API or
simulate loss of the host storage cache. See [QEMU activation](QEMU.md#maintained-vm-activation)
for the activation-specific fault and SSH checks.

### Use the fixed xinit tool snapshot

The independent checks use frozen `bin/{xsh,xshi,xsht}` and matching `core/`
inputs. The supplied `xinit-optional-condition` verification build contains
XSH `7261b0420` plus the user's optional-condition verifier repair.
It compiles xinit and passes the native and disposable-container lifecycle tests.
Point `XSH_HOST`, `XSHT`, and `XSH_ROOT` at that snapshot. Set
`XSH_MODULE_PATH` to this checkout. Do not rebuild a moving sibling checkout
while comparing results.

The earlier XSH `7577228454b70be816066fe20d97443dd05dae11` and `f286c59e4`
builds reject this minimized case before any function executes:

```xsh
type ReadyService = module {
  export optional proc ready() [fs, process, env, time, error] -> Result[Bool, Error]
}

proc wait_ready(service_path: Path) -> Result[Bool] {
  let loaded = module.load(service_path)?.require(ReadyService)?
  return true when "ready" not in loaded.keys()
  return true when loaded.ready()
  false
}

print "checked"
```

Their diagnostic is `compact.indexed-build`, with `condition producer has no
checked contract` at `ExprTry`. Both implicit propagation and an explicit `?`
now pass in the supplied repaired build. This was a compiler regression,
not a service-file change.

### Run the independent operational checks

The [closed cohort](DEVELOPMENT.md#closed-cohort-qualification) builds three
actual C, Rust, and XSH packages in two restricted containers. The x86_64 run
passed authority probes and matched all three artifact keys, payload digests,
and archive bytes across different checkout paths and ambient environments.
The native suites do not require Docker.

Follow the [xinit guest instructions](../xinit/tests/README.md) for seeded
scanner actions and the reduced leader-crash replay. These checks use actual
Linux process groups in disposable Docker PID namespaces. The separate PID 1
mode verifies all five signal dispatches and cleanup with zero capabilities.
It expects EPERM from final machine-control syscalls. Controlled startup and
finish-hook interruptions and a bounded failure reducer cover additional
boundaries. Asterinas, aarch64, SIGKILL of the scanner, and disk power loss
remain separate qualification.

The [headless self-hosting proof](SELF-HOSTING.md) builds replacement xsh/xsht
from saved source and crates inside a Linux x86_64 KVM guest. The replacement
rebuilds the closed cohort and composes successor B. Both B and the preserved A
boot with their expected receipts and runner hashes. The same guest qualifies
wall-clock jumps, QMP pause/resume, and the reduced leader-crash counterexample.
This opt-in proof uses declared bootstrap tools and does not qualify a complete
self-hosted package world or production activation.

Run `bash tests/system/network_policy_docker.sh TOOL_SNAPSHOT` to capture a
bounded real virtual-interface observation and reproduce its ownership conflict
offline. This read-only check does not mutate host networking or qualify
reconciliation after partial kernel operations.

The real manual-index check is opt-in:

```bash
(cd packages/mandoc && \
  LAPUTA_MANUAL_INDEX_TOOL_ROOT=/absolute/path/to/mandoc-root \
  "$XSHT" test --jobs 1 tests/manual_index.xsh)
```

Use an absolute `XSHT` path. The package-local configuration discovers this
opt-in test without adding it to the default native suite. Supply a root containing the target's pinned musl mandoc programs and loader.
The check composes two generations, queries original and overlaid manual pages,
compares index bytes, detects alteration or deletion, and preserves the prior
generation when index creation fails. It does not use host `makewhatis`.

## Run bounded PM and kernel cases

```bash
$XSHT test --jobs 1 tests/pm/pyramid_cases.xsh
$XSHT test --jobs 1 packages/linux/tests/pyramid.xsh
```

The PM cases resolve three fixture packages and check the exact node, action,
and dependency inventory. The execution case prepares two dependencies in a
disposable store, builds one fresh application, and reuses all three on rerun.
Each fixture build fails if executed twice. Root composition checks the exact
path owners, package manifests, symlink target, and runtime payloads.
The executor requires sibling `xsh`, `xshi`, and `xsht` products.

The kernel stop cases discover and plan one synthetic object without compiling it.
`packages/linux/kbuild_verify.xsh::linux_kbuild_verify_stopped` accepts the
recipe's `linux-kbuild-stopped` error only for the requested stage.
Preparation requires nonempty `.config` and `include/generated/autoconf.h`.
Discovery also requires a readable report with a root directory, selected
objects, and no unsupported inputs. Planning also requires a complete,
nonempty archive task report. Other error families retain their original cause.

The kernel graph cases cover four objects in two directories and 32 objects
in eight directories. Their exact graphs contain seven and 41 tasks.
Each case first executes one archive closure, then the complete synthetic graph.
A no-op rerun executes nothing. Changing one source executes its object task,
its directory archive, and the root archive. Another no-op rerun executes nothing.
XSH fixture commands replace compiler and archiver argv while preserving the
Kbuild task inputs, outputs, dependencies, working directories, and stamps.
The fixtures use explicit inputs without compiler depfiles and set deterministic
file timestamps. They check scheduler work and output contents, without measuring
compiler behavior or performance.

These commands do not run a world build, a real kernel build, or a VM.
Real pinned discovery and planning require a separately selected scenario.
Fresh world construction, full kernel compilation and linking, and VM proofs
require an explicit manual request.

## Run explicit pinned kernel discovery

```bash
xsh packages/linux/discover_case.xsh -- PREPARED_SOURCE
```

Run this explicit discovery command from the checkout root. `PREPARED_SOURCE`
is a fresh source tree under this checkout's `.work/tmp`. Before preparing that
tree, verify the recipe's archive pin and enforce a 256 MiB archive cap and a
2 GiB expanded-source cap. Keep exclusive ownership of the prepared tree until
the command returns. Source acquisition and extraction stay with the existing
PM source and archive owners. This command accepts prepared inputs.
It performs no fetch, extraction, host preparation, compilation, or linking.

The command loads typed Linux metadata through `pm.recipe`, verifies the
selected x86 configuration checksum, and rejects symlinked output paths before
writing. It writes `.config`, generated configuration headers, and the existing
`.xsh-kbuild-plan.json` inventory. Discovery uses one worker, no plan cache,
and the exact `linux-kbuild-stopped` discovery oracle. The controller still
owns source freshness, expected inventory, resource admission, and result binding.

Run the focused preparation controls with matching compiler products:

```bash
$XSHT test --jobs 1 test_pyramid_prepared_discovery
```

These controls check the exact synthetic inventory, configuration checksum,
output symlinks, source confinement, and restoration of the stop environment.
Compiler preparation must succeed before a test body can establish behavior.
A named stop, an arbitrary nonzero exit, or a report's presence cannot establish
successful discovery.

The command preserves the caller's source tree on failure. Configuration,
headers, or a discovery report can remain for diagnosis. After consuming the
result, remove the controller-owned tree and prepare a fresh tree for another
run. Container and reservation cleanup remain with the controller. Functional
discovery evidence does not establish P0 timing or qualify a kernel build.
