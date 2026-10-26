# Check kernel configuration drift

Run this host-side reference check after changing the kernel pin or either
configuration fragment. It runs upstream `olddefconfig` for both architectures
and reports every changed symbol. Any difference exits unsuccessfully.
The check leaves the checked-in fragments unchanged.

Use the verified Linux source from
[`upstream_pins.xsh`](../upstream_pins.xsh) and the verified LLVM archive from
[`llvm-toolchain/PKGBUILD.xsh`](../llvm-toolchain/PKGBUILD.xsh).
Extract both under `.work/tmp`. Supply the extracted LLVM `bin` directory,
a fresh output directory, and a host C compiler that can link executables.
The checker rejects a Linux release or clang version that differs from those pins.

From the repository root, with GNU make, bison, flex, and the host compiler
available on `PATH`, run:

```sh
export TMPDIR="$PWD/.work/tmp"
export PATH="$LLVM_BIN:$PATH"
xsh packages/linux/check_config.xsh -- "$LINUX_SOURCE" "$LLVM_BIN" \
  .work/tmp/kernel-config-check /usr/bin/cc
```

`LLVM_BIN` is an absolute path. LLVM target probes use that directory explicitly.
`HOSTCC` builds only the Kconfig host tools.
Rust, bindgen, and pahole probes use deliberately unavailable paths, matching
the fragment regeneration procedure. The checker never overwrites an existing
architecture output directory.

The comparison ignores headings and ordering. It preserves literal string
values, including embedded equals signs, and distinguishes absent symbols
from disabled symbols. Review added, removed, and changed symbols before
updating a fragment. A changed fragment also needs its recipe checksum updated.

This command invokes upstream GNU make as a host-side reference check.
The package build continues to use native XSH Kbuild.

Run the focused comparator tests with:

```sh
xsht test packages/linux/tests/config_drift.xsh
```
