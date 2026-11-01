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
build inputs. `asterinas-build` builds or reuses the Asterinas PVH kernel and
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
`bash infra/asterinas/run-ktest.sh ostd` or
`bash infra/asterinas/run-ktest.sh osdk/deps/frame-allocator`. The runner boots
the OSDK test kernel in QEMU with KVM and two CPUs, and fails unless every test
passes. It needs a prior `make asterinas-build` for the OSDK install.

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
for the full native suite or qualify device, clock, or network compatibility.

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

