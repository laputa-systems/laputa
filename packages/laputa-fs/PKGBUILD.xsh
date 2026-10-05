##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export const name = "laputa-fs"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1"

## Exported declaration `rel`.
export const rel = "10"

## Exported declaration `deps`.
export let deps = []

## The build installs XSH scripts; they need the `xsh` runner at runtime.
export const runtime_only_deps = ["xsh"]

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"files/mkfs.vfat.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
  {
    source: p"files/mkfs.ext4.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
  {
    source: p"files/fsck.ext4.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
  {
    source: p"files/fat-put.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/bin/fsck.ext4",
    kind: "file",
  },
  {
    path: p"usr/bin/mkfs.ext4",
    kind: "file",
  },
  {
    path: p"usr/bin/mkfs.vfat",
    kind: "file",
  },
  {
    path: p"usr/lib/laputa-fs/fat-put",
    kind: "file",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, error] {
  fs.install(p"mkfs.vfat.xsh", fp"{dest}/usr/bin/mkfs.vfat", 0o755, parents: true, overwrite: true)
  fs.install(p"mkfs.ext4.xsh", fp"{dest}/usr/bin/mkfs.ext4", 0o755, parents: true, overwrite: true)
  fs.install(p"fsck.ext4.xsh", fp"{dest}/usr/bin/fsck.ext4", 0o755, parents: true, overwrite: true)
  fs.install(p"fat-put.xsh", fp"{dest}/usr/lib/laputa-fs/fat-put", 0o755, parents: true, overwrite: true)
}
