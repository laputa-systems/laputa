# Asterinas and Firecracker

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
the `guest/asterinas/network-state` case in each mode (including `events`, which compares the route-netlink notifications) against a TAP-backed `eth0`
and requires the two `NET_` transcripts to be identical. Two normalizations apply:
the Linux reference has a `sit0` link, which the case omits, and IPv6 is outside the
cohort (the reference kernel has no IPv6 policy routing and adds link-local addresses),
so IPv6 address, route and rule lines are not compared.
The cohort uses whichever bundle `make asterinas-build` last selected.

Run the DHCP cohort with `bash infra/asterinas/qualify.sh network --backend both [--case NAME]`.
It runs the `proc_boot_id` and `udp_device` witnesses, then each mode of `guest/asterinas/dhcp`
(`lease-acquire`, `lifecycle`, `renewal`, `reconfigure`, `nak`, `restart`, `carrier`, `tcp`) against the same
TAP-backed `eth0`. The container end of the TAP runs the XSH pin's scripted DHCP server
(and, for `tcp`, a C payload server) from the case's `peer.sh`; the guest runs the packaged `dhcpc`.
The `NET_` transcripts of the two kernels must match. A mode takes 40 to 80 s per backend.

The remaining cohorts run the same way. `device` runs the baseline boot proof, whose
guest coldplugs three times and after a daemon restart, the `device/block_uevent` and `fs/sync/writeback` witnesses and
the modes of `guest/asterinas/device`: `sysfs`, `add` and `nodes` compare the device paths,
uevent data, synthetic add events and coldplugged node ownership of two disks, their partitions
and the memory devices with the Linux reference (the case ships `data-disk.sh`, which makes the
second disk both guests attach), and `missing` is a negative control that must fail with a
missing add event on both backends. `clock-abi` runs the `time/clock_adjust` witness. `clock` runs the
`network/udp_ancillary` witness and the `guest/asterinas/clock` case in the modes
`behind`, `ahead`, `frequency`, `pause` and `jump` (the last two on a TAP-backed network
with an outside peer). `recovery` repeats the boot proof and the DHCP `restart` and
`carrier` modes `LAPUTA_RECOVERY_REPEATS` times (10 by default). `all` runs `baseline`,
`device`, `clock-abi`, `clock`, `network-state`, `network` and `recovery` serially and
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
exists only locally is red until the fork's `main` is published. The caches are removed on exit.

To account for many modules, run
`bash infra/asterinas/native-batches.sh asterinas MODULES BATCH_SIZE BUDGET_SECONDS DIR`
(or `linux`) on a list of test modules, then
`bash infra/asterinas/account-native.sh DISCOVERED_IDS.json DIR [--baseline ACCOUNTING.json]`.
Each batch boots one guest from the built bundle. A guest that dies mid-batch
returns its in-flight module to the pending list once and records it as
interrupted if it dies alone. Modules left when the budget ends are written to
`unstarted.txt`; the accounting counts their cases and those of interrupted
modules as unexecuted. The accounting exits nonzero when it finds no results, a
result for an undiscovered case, or a baseline case that no longer passes.
To compare against the original A0 pass set, use
`bash infra/asterinas/account-native.sh DISCOVERED_IDS.json DIR --baseline infra/asterinas/a0-baseline.json`.

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

