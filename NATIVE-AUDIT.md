# Native Surface Audit

This audit tracks code and tooling in the Laputa stack that is not native XSH.
It is not a mandate to remove all non-XSH code: package builds still compile C,
C++, assembly, Rust, and upstream project sources. The goal is to keep
orchestration and generated compatibility code visible so cleanup work is
deliberate.

## Integration Repo

- `Makefile`: host entrypoints and Docker/QEMU orchestration. It remains the
  main non-XSH control plane.
- `Dockerfile.*`: image and proof builders. These are expected while Docker is
  the packaging/proof substrate.
- `installer-qemu-test.xsh`: QEMU CI harness. It owns QEMU process control,
  markers, timeout handling, and SSH smoke assertions.
- `boot/qmp-proof.py`: QMP interaction for screenshots and input injection.
  This is the largest remaining Python-only integration helper.
- `boot.xsh`: mostly XSH, but still shells out to Docker, `sh`, `tar`, `file`,
  QEMU, SSH, and Tailscale CLIs where those are the external systems under
  test or the current host interface.

## Package Repo

Checked-in generated/package source inputs:

- `repo/linux/files/generated/*`
- `repo/linux/files/sysreg-defs.h`
- `repo/linux/files/x86-jump-label-patch.c`
- `repo/libxkbcommon/files/parser.c` and `parser.h`
- `repo/tmux/files/cmd-parse.c` and `cmd-parse.h`
- `repo/fcft-minimal/files/generated/*`
- `repo/fontconfig/files/generated/*`
- `repo/foot-minimal/files/generated/*`

Package-local generated or stub C code written from XSH package scripts:

- `alsa-lib`, `eudev-lite`, `iptables`, `libdisplay-info`,
  `mesa-minimal`, `llvm-toolchain`, `bison`, `fontconfig`, and `flex`
  generate or compile local C helper/stub sources.

Native XSH replacements already exist for some historically external tools:

- `repo/bison/files/bison.xsh`
- `repo/flex/files/flex.xsh`
- `repo/m4/files/m4.xsh`
- `repo/laputa-fs/files/*.xsh`
- `repo/linux/kbuild.xsh` and related Linux package build logic

## Cleanup Queue

- Replace `boot/qmp-proof.py` with an XSH QMP client once the JSON/socket path
  is ergonomic enough.
- Keep installer QEMU orchestration in `installer-qemu-test.xsh`.
