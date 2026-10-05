##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export const name = "ca-certificates"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "2026.09.25"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export let deps = []

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

## `/usr/bin/update-certdata` is an XSH script; it needs the `xsh` runner at runtime.
export const runtime_only_deps = ["xsh"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"files/cacert.pem",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505",
      },
    ],
  },
  {
    source: p"files/update-certdata.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "dab92b221c2cd883ff6292e1aeafc075d687202318dcbea320e80a1c15f77ad1",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"etc/ssl/cert.pem",
    kind: "symlink",
  },
  {
    path: p"etc/ssl/certs/ca-certificates.crt",
    kind: "file",
  },
  {
    path: p"usr/bin/update-certdata",
    kind: "file",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, error] {
  fs.install(p"cacert.pem", fp"{dest}/etc/ssl/certs/ca-certificates.crt", 0o644, parents: true, overwrite: true)
  fp"{dest}/etc/ssl".mkdir()
  fs.symlink(p"certs/ca-certificates.crt", fp"{dest}/etc/ssl/cert.pem")
  fs.install(p"update-certdata.xsh", fp"{dest}/usr/bin/update-certdata", 0o755, parents: true, overwrite: true)
}
