##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export const name = "ca-certificates"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "2026.10.20"

## Exported declaration `rel`.
export const rel = "2"

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
  {
    source: p"files/trust-policy",
    kind: "file",
    architectures: ["all"],
    checksums: [
      {
        arch: "all",
        sha256: "c42736ba5db8a2224e14dfd527a8c80eb955e2cdbcfacbe4d35f5806076a196d",
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
    path: p"etc/laputa/trust-policy",
    kind: "file",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, error] {
  fs.install(p"cacert.pem", fp"{dest}/etc/ssl/certs/ca-certificates.crt", 0o644, parents: true, overwrite: true)
  fs.install(p"trust-policy", fp"{dest}/etc/laputa/trust-policy", 0o644, parents: true, overwrite: true)
  fp"{dest}/etc/ssl".mkdir()
  fp"{dest}/etc/ssl/cert.pem".symlink(to: p"certs/ca-certificates.crt")
}
