##! Package recipe for bounded persistent diagnostics.
export const name = "laputa-diagnostics"

## Payload package.
export const package_kind = "payload"

## Package version.
export const ver = "1"

## Package release.
export const rel = "1"

## Runtime packages are provided by the image roots.
export let deps = []

## The collector is XSH and reads the XSH system-report applets.
export const runtime_only_deps = ["xinit", "xsh"]

## No host build tools.
export let mkdeps_host = []

## The collector lives in this checkout; the service is package-owned.
export const upstream_sources = [
  {
    source: p"repository/system/diagnostics.xsh",
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

## The collector and its xinit oneshot service.
export const filetree = [
  {
    path: p"usr/lib/laputa/diagnostics.xsh",
    kind: "file",
  },
  {
    path: p"usr/lib/xinit/services/diagnostics.xsh",
    kind: "file",
  },
]

## Install the XSH collector and service module.
export proc build(dest: Path) [fs, error] {
  fs.install(p"repository/system/diagnostics.xsh", fp"{dest}/usr/lib/laputa/diagnostics.xsh", 0o644, parents: true, overwrite: true)
  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/diagnostics.xsh", 0o644, parents: true, overwrite: true)
}
