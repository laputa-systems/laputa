##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export const name = "ca-certificates"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "2026.10.20"

## Exported declaration `rel`.
export const rel = "3"

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
  {
    source: p"files/trust-update-key",
    kind: "file",
    architectures: ["all"],
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
    path: p"etc/ssl/cert.pem",
    kind: "symlink",
  },
  {
    path: p"etc/ssl/certs/ca-certificates.crt",
    kind: "symlink",
  },
  {
    path: p"etc/laputa/trust-policy",
    kind: "symlink",
  },
  {
    path: p"etc/laputa/trust-update-key",
    kind: "file",
  },
  {
    path: p"usr/share/laputa/trust/seed/ca-certificates.crt",
    kind: "file",
  },
  {
    path: p"usr/share/laputa/trust/seed/trust-policy",
    kind: "file",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, error] {
  let key_source = p"trust-update-key"
  guard key_source.exists() else {
    return Err(
      CaCertificatesBuildError.Failed(
        kind: "ca-certificates-key",
        message: "ca-certificates requires an operator-provisioned trust-update key at packages/ca-certificates/files/trust-update-key; see docs/CERTIFICATE-TRUST.md (key ceremony)",
      ),
    )
  }

  let key = key_source.read_bytes()?
  guard key.len() == 32 else {
    return Err(
      CaCertificatesBuildError.Failed(
        kind: "ca-certificates-key",
        message: "provisioned trust-update key must contain exactly 32 raw Ed25519 bytes",
      ),
    )
  }

  fs.install(p"cacert.pem", fp"{dest}/usr/share/laputa/trust/seed/ca-certificates.crt", 0o644, parents: true, overwrite: true)
  fs.install(p"trust-policy", fp"{dest}/usr/share/laputa/trust/seed/trust-policy", 0o644, parents: true, overwrite: true)
  fs.install(key_source, fp"{dest}/etc/laputa/trust-update-key", 0o444, parents: true, overwrite: true)
  fp"{dest}/etc/ssl/certs".mkdir(parents: true)
  fp"{dest}/etc/ssl/cert.pem".symlink(to: p"certs/ca-certificates.crt")
  fp"{dest}/etc/ssl/certs/ca-certificates.crt".symlink(to: p"../../../var/lib/laputa/trust/active/ca-certificates.crt")
  fp"{dest}/etc/laputa/trust-policy".symlink(to: p"../../var/lib/laputa/trust/active/trust-policy")
}

error CaCertificatesBuildError = Failed(kind: Str, message: Str)
