# Asterinas and Firecracker

The Asterinas backend uses the exact kernel, toolchain, Firecracker, and XSH
versions recorded in `infra/asterinas/inputs.lock`. On x86-64 Linux with KVM
and Docker, plus a C compiler and the host `find` and `sort` tools, start with:

```bash
make asterinas-preflight
make asterinas-fetch
make asterinas-build
```

`asterinas-preflight` only checks host capabilities and input declarations.
`asterinas-fetch` fetches the pinned Asterinas and XSH source plus the declared
build inputs. `asterinas-build` builds or reuses the Asterinas PVH kernel and
the Laputa generation, then publishes a content-addressed bundle. Changes in
the sibling XSH working tree do not affect this pinned build.

The kernel, verified immutable bundles, runtime disk copies, Firecracker
configuration, build and boot logs live under `.out/asterinas-firecracker/`.
Fetched Asterinas and XSH repositories remain under `.cache/asterinas/`.
`asterinas-clean` runs `make distclean`, removing the checkout's outputs,
shared PM artifact store, fetched caches, and the pinned build-tool images for
a cold rebuild from pinned inputs. It keeps the tracked source
checkouts. The ordinary `asterinas-setup` target also offers a small
kernel/VMM smoke boot.

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

Run one native XSH test module from the locked XSH snapshot inside the guest
with `XSH_TEST=tests/xsh/stdlib/numeric.xsh`. A module under `core/tests`,
`dev/tests`, or `showcase/tests` can be selected the same way. Use
`XSH_TEST=core/tests/test-awk.xsh::test_awk_matrix_arrays_and_functions` to
run one exact test. Use `XSH_TEST=all` to run the full
native suite configured by the pinned `xsht-config.ini`, including `core/tests`,
`dev/tests`, `tests`, and `showcase/tests`. The test source tree is staged from
the locked Git archive through a PM generation overlay; its digest is included
in the immutable bundle manifest. Guest test runs use 4 GiB of memory; the
base viability proof uses 1 GiB. The selected tests run under the packaged
`xsht`, and the host requires their guest success marker. To test a different
XSH source revision, update the XSH commit pin in `infra/asterinas/inputs.lock`
first.

Use module or exact-test selections for focused checks; `XSH_TEST=all` runs
the entire suite in a 2-vCPU guest.

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
Firecracker; Ctrl-C interrupts xshi. `asterinas-shell` remains a legacy alias.

