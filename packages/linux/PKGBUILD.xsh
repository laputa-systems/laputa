##! Linux package metadata and the dynamic recipe boundary.

## Exported declaration `name`.
export const name = "linux"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "7.2.9"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps: List[Str] = []

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "flex", "bison"]

## Exported declaration `nostrip`.
export const nostrip = true

# The config fragments and generated inputs track the kernel release; after
# a version change, regenerate them on the host from an extracted tarball,
# with the pinned LLVM (the llvm-toolchain tarball) as LLVM=<dir>/bin/ and
# RUSTC, BINDGEN and PAHOLE pointed at missing tools so host Rust does not
# leak into Kconfig. Each step uses an out-of-tree O= directory.
# - files/config/<arch>/base-<arch>.fragment: copy the current fragment to
#   O/.config, run `make ARCH=<x86_64|arm64> LLVM=... HOSTCC=gcc
#   olddefconfig`, and keep O/.config.
# - With that config, `make ... prepare` writes the rest:
#   - files/generated/bounds.h and rq-offsets.h: O/include/generated/ (arm64;
#     x86 compiles them during the build);
#   - files/sysreg-defs.h: O/arch/arm64/include/generated/asm/sysreg-defs.h;
#   - files/generated/cpufeaturemasks-x86.h:
#     O/arch/x86/include/generated/asm/cpufeaturemasks.h;
#   - files/generated/timeconst.h: O/include/generated/timeconst.h (depends
#     only on CONFIG_HZ, which both arches set to 250).
# - files/generated/inat-tables-x86.c: `awk -f
#   arch/x86/tools/gen-insn-attr-x86.awk arch/x86/lib/x86-opcode-map.txt`.
# - files/generated/sha256-core.S and sha512-core.S: `perl
#   lib/crypto/arm64/sha2-armv8.pl void <out>` with the output name.
## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.9.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b4c5dfbe51a364a6c7f03869200f88c8e1f77403539005f14b7fc6bc91b8d8ba",
      },
    ],
  },
  {
    source: p"files/config/aarch64/base-aarch64.fragment => .laputa-inputs/files/config/aarch64",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "2c273f3751472adb893fec0a1d8637a940456a737b73f36a665d38988d69bec7",
      },
    ],
  },
  {
    source: p"files/config/x86_64/base-x86_64.fragment => .laputa-inputs/files/config/x86_64",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "44fd9e092e8dc9aa994b8d768a306289cd1cd7d2c0369c4c9961686384dd7994",
      },
    ],
  },
  {
    source: p"files/sysreg-defs.h",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "30a702fcb9e77bbe2d2e699f8b8f1986f2e42b362115723faf508087505fd422",
      },
    ],
  },
  {
    source: p"files/generated/timeconst.h",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "664c2e5a8ed45eb327f0f1b1ee83249a24f98ee67f3bcb313a4d0bf99202ceed",
      },
    ],
  },
  {
    source: p"files/generated/bounds.h",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "c7daffc2aa5a964969421942bb000e65a2b9866d2a2a11529689c379005ef1f1",
      },
    ],
  },
  {
    source: p"files/generated/rq-offsets.h",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "8c4e70118cb529cc043fdbd0ffa3d73a4cc6432df99c33aa63a4a32919389b30",
      },
    ],
  },
  {
    source: p"files/generated/sha256-core.S",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "1b7d66d6d221e3663be0da7d0516564e6d5d10c07e8c0612ee0ac87bcb9dc519",
      },
    ],
  },
  {
    source: p"files/generated/sha512-core.S",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "527009fbdd1faa79dee68028a3fd92440412c24e29ec95b32718f911216d27ec",
      },
    ],
  },
  {
    source: p"files/generated/cpufeaturemasks-x86.h",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "7abeb73bfd7ad632543e19348adf7894b4340b237e1ceeb08432692d2492eaae",
      },
    ],
  },
  {
    source: p"files/generated/inat-tables-x86.c",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "5bc098c57c3bfaa8d3fbd05f6d7703c5573417431a48160a194961e7cf334525",
      },
    ],
  },
  {
    source: p"files/x86-jump-label-patch.c",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "39fa47de004dc15b2d71fad9256734992f93743cdb65ef1a70d454b0403f5031",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [{path: p"boot", kind: "tree"}, {path: p"usr", kind: "tree"}]

## The PM dynamic loader reads this metadata on every catalog scan.  The
## Kbuild program is deliberately executed in a child XSH process instead of
## imported here: the pinned published runner cannot dynamic-load its indexed
## IR, while normal script execution remains supported.
export proc build(dest: Path) [process, env, error] {
  let recipe_dir = env.get("XSH_PM_RECIPE_DIR") ?? ""
  let xsh = process.which("xsh")?
  run $xsh fp"{recipe_dir}/PKGBUILD-build.xsh" "--" $dest ?
}
