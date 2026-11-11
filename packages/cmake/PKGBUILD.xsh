##! CMake prebuilt package definition and install operations.
## Package name.
export const name = "cmake"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Upstream CMake version.
export const ver = "4.4.5"

## Package release revision.
export const rel = "1"

## The prebuilt programs are static PIE and import no shared libraries.
export const deps: List[Str] = []

## Installing the prebuilt tree needs no host build tools.
export const mkdeps_host: List[Str] = []

## Preserve upstream binaries without stripping.
export const nostrip = true

## Qualified prebuilt archives and their per-architecture checksums.
export const upstream_sources = [
  {
    source: p"https://github.com/laputa-systems/cmake-build/releases/download/cmake-VERSION-40f84aef2341-run42938731214-1/cmake-VERSION-ARCH-unknown-linux-musl.tar.xz => cmake-prebuilt",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "d05210064fb9a5a6bde7c663a4e9c1336bd9d53f6e3bc1b1d0b9fd14437b1057",
      },
      {
        arch: "x86_64",
        sha256: "fc6ed71475af45e4db67895addffaffd291588d12c49190d734dcafa2b73d73b",
      },
    ],
  },
]

## Installed package file tree.
export const filetree = [
  {
    path: p"usr",
    kind: "tree",
  },
  {
    path: p"usr/bin/cmake",
    kind: "binary",
  },
  {
    path: p"usr/bin/cpack",
    kind: "binary",
  },
  {
    path: p"usr/bin/ctest",
    kind: "binary",
  },
  {
    path: p"usr/share/cmake",
    kind: "tree",
  },
  {
    path: p"usr/share/doc/cmake-build/licenses/rust-std/alloc-0.0.0",
    kind: "symlink",
  },
  {
    path: p"usr/share/doc/cmake-build/licenses/rust-std/core-0.0.0",
    kind: "symlink",
  },
  {
    path: p"usr/share/doc/cmake-build/licenses/rust-std/panic_abort-0.0.0",
    kind: "symlink",
  },
  {
    path: p"usr/share/doc/cmake-build/licenses/rust-std/panic_unwind-0.0.0",
    kind: "symlink",
  },
  {
    path: p"usr/share/doc/cmake-build/licenses/rust-std/rustc-std-workspace-alloc-1.99.0",
    kind: "symlink",
  },
  {
    path: p"usr/share/doc/cmake-build/licenses/rust-std/rustc-std-workspace-core-1.99.0",
    kind: "symlink",
  },
  {
    path: p"usr/share/doc/cmake-build/licenses/rust-std/std-0.0.0",
    kind: "symlink",
  },
  {
    path: p"usr/share/doc/cmake-build/licenses/rust-std/std_detect-0.1.5",
    kind: "symlink",
  },
  {
    path: p"usr/share/doc/cmake-build/licenses/rust-std/unwind-0.0.0",
    kind: "symlink",
  },
]

## Install the unpacked prebuilt tree.
export proc build(dest: Path) [fs, error] {
  let source = p"cmake-prebuilt"
  let target = fp"{dest}/usr"

  guard source.exists() else {
    fail "missing staged CMake prebuilt tree"
  }

  let _ = fs.copy_tree(source, target, parents: true, overwrite: true)?
  # The cmake-build tarball ships `share/cmake` as a compatibility symlink to
  # `share/cmake-<ver>`, which cannot merge with the CMake package configs other
  # packages install beneath `share/cmake`.
  let share_cmake = fp"{dest}/usr/share/cmake"

  if share_cmake.is_symlink() {
    share_cmake.remove()
  }

  if ! share_cmake.exists() {
    share_cmake.mkdir()
  }
}
