##! Package recipe for the scheduled rustic backup runner and quiesce hook.

## Package name.
export const name = "laputa-backup"

## Payload package.
export const package_kind = "payload"

## Package version.
export const ver = "1"

## Package release.
export const rel = "1"

## Runtime packages are provided by the image roots.
export let deps = []

## The runner is XSH and needs the packaged rustic binary.
export const runtime_only_deps = ["xinit", "xsh", "rustic"]

## No host build tools.
export let mkdeps_host = []

## The runner and hook live in this checkout.
export const upstream_sources = [
  {
    source: p"repository/system/backup.xsh",
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
    source: p"repository/system/backup_quiesce.xsh",
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

## The backup runner and the xinit quiesce hook.
export const filetree = [
  {
    path: p"usr/lib/laputa/backup.xsh",
    kind: "file",
  },
  {
    path: p"usr/lib/laputa/backup-quiesce.xsh",
    kind: "file",
  },
]

## Install the runner and the quiesce hook.
export proc build(dest: Path) [fs, error] {
  fs.install(p"backup.xsh", fp"{dest}/usr/lib/laputa/backup.xsh", 0o755, parents: true, overwrite: true)
  fs.install(p"backup_quiesce.xsh", fp"{dest}/usr/lib/laputa/backup-quiesce.xsh", 0o755, parents: true, overwrite: true)
}
