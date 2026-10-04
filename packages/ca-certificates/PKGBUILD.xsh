##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export let name = "ca-certificates"

## Explicit payload or metapackage classification.
export let package_kind = "payload"

## Exported declaration `ver`.
export let ver = "2026.03.19"

## Exported declaration `rel`.
export let rel = "10"

## Exported declaration `deps`.
export let deps = []

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

## `/usr/bin/update-certdata` is an XSH script; it needs the `xsh` runner at runtime.
export let runtime_only_deps = ["xsh"]

## Exported declaration `upstream_sources`.
export let upstream_sources = [
  {
    source: p"files/cacert.pem",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b6e66569cc3d438dd5abe514d0df50005d570bfc96c14dca8f768d020cb96171",
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
        sha256: "2bf7c327badcf18ec562b342c9e55e8e004059daebb348f7ef67b973a3e57ff2",
      },
    ],
  },
]

## Exported declaration `filetree`.
export let filetree = [
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
  fs.install(p"cacert.pem", fp"{dest}/etc/ssl/certs/ca-certificates.crt", 0o644, parents: true, overwrite: true)?
  fs.mkdir(fp"{dest}/etc/ssl")?
  fs.symlink(p"certs/ca-certificates.crt", fp"{dest}/etc/ssl/cert.pem")?
  fs.install(p"update-certdata.xsh", fp"{dest}/usr/bin/update-certdata", 0o755, parents: true, overwrite: true)?
}
