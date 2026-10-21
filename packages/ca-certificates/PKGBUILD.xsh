##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export const name = "ca-certificates"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "2026.10.20"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export let deps = []

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

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
        sha256: "796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe",
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
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, error] {
  fs.install(p"cacert.pem", fp"{dest}/etc/ssl/certs/ca-certificates.crt", 0o644, parents: true, overwrite: true)
  fp"{dest}/etc/ssl".mkdir()
  fp"{dest}/etc/ssl/cert.pem".symlink(to: p"certs/ca-certificates.crt")
}
