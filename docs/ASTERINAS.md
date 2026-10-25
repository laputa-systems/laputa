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
run one exact test. Use `XSH_TEST=all` to run the full
native suite in a 2-vCPU guest configured by the pinned `xsht-config.ini`, including `core/tests`,
`dev/tests`, `tests`, and `showcase/tests`. The test source tree is staged from
the locked Git archive through a PM generation overlay; its digest is included
in the immutable bundle manifest. Guest test runs use 4 GiB of memory; the
base viability proof uses 1 GiB. The selected tests run under the packaged
`xsht`, and the host requires their guest success marker. To test a different
XSH source revision, update the XSH commit pin in `infra/asterinas/inputs.lock`
first.

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

