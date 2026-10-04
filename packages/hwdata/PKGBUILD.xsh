##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export const name = "hwdata"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "0.412"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export let deps = []

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://github.com/vcrhonek/hwdata/archive/refs/tags/vVERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "f0c64cd7e31d70a5fb3a52e53ab50a61e74c0421a6381eaa45114eec3bde5fe7",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/share/hwdata/pci.ids",
    kind: "file",
  },
  {
    path: p"usr/share/hwdata/pnp.ids",
    kind: "file",
  },
  {
    path: p"usr/share/pkgconfig/hwdata.pc",
    kind: "file",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, error] {
  fs.mkdir(fp"{dest}/usr/share/hwdata")?
  fs.install(p"pnp.ids", fp"{dest}/usr/share/hwdata/pnp.ids", 0o644, parents: true, overwrite: true)?
  fs.install(p"pci.ids", fp"{dest}/usr/share/hwdata/pci.ids", 0o644, parents: true, overwrite: true)?
  fs.mkdir(fp"{dest}/usr/share/pkgconfig")?

  fs.write(
    fp"{dest}/usr/share/pkgconfig/hwdata.pc",
    """prefix=/usr
datadir=\${prefix}/share
pkgdatadir=\${datadir}/hwdata

Name: hwdata
Description: Hardware identification data
""" + f"Version: {ver}\n",
  )?
}
