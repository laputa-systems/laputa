##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export const name = "laputa-syslog"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export let deps = []

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

## The build installs the logger service module; xinit runs it at runtime,
## and the syslogd applet comes from the xsh core.
export const runtime_only_deps = ["xinit", "xsh"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"service.xsh",
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
    path: p"usr/lib/xinit/services/logger.xsh",
    kind: "file",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, error] {
  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/logger.xsh", 0o644, parents: true, overwrite: true)
}
