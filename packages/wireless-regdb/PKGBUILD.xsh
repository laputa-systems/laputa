##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "wireless-regdb"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "2026.09.03"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps: List[Str] = []

## Package recipe export.
export const mkdeps_host: List[Str] = []

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://mirrors.edge.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b22e0901227b820cd1c280abe681a15b773a5103a5e10dc442e94ebb34cbf58d",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/lib/firmware/regulatory.db",
    kind: "file",
  },
  {
    path: p"usr/lib/firmware/regulatory.db.p7s",
    kind: "file",
  },
  {
    path: p"usr/share/licenses/wireless-regdb/LICENSE",
    kind: "file",
  },
]

# cfg80211 requests regulatory.db and its PKCS#7 signature through the kernel
# firmware loader, which searches /lib/firmware; baselayout makes /lib a
# symlink to usr/lib, so the files belong under usr/lib/firmware. The database
# ships prebuilt and signed in the release tarball, so nothing is regenerated.
## Package recipe export.
export proc build(dest: Path) [fs, error] {
  let firmware = fp"{dest}/usr/lib/firmware"
  fs.install(p"regulatory.db", fp"{firmware}/regulatory.db", 0o644, parents: true, overwrite: true)
  fs.install(p"regulatory.db.p7s", fp"{firmware}/regulatory.db.p7s", 0o644, parents: true, overwrite: true)
  fs.install(p"LICENSE", fp"{dest}/usr/share/licenses/wireless-regdb/LICENSE", 0o644, parents: true, overwrite: true)
}
