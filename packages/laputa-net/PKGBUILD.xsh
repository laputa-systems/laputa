##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export let name = "laputa-net"

## Explicit payload or metapackage classification.
export let package_kind = "payload"

## Exported declaration `ver`.
export let ver = "1"

## Exported declaration `rel`.
export let rel = "11"

## Exported declaration `deps`.
export let deps = []

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

## The build only installs the service module and interface config. At runtime
## xinit runs the service, which drives the xsh core applets ifup/ifdown, and
## wpa_supplicant provides Wi-Fi association for wireless interfaces.
export let runtime_only_deps = ["wpa_supplicant", "xinit", "xsh"]

## Exported declaration `upstream_sources`.
export let upstream_sources = [
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
  {
    source: p"interfaces",
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
export let filetree = [
  {
    path: p"etc/network/if-down.d",
    kind: "tree",
  },
  {
    path: p"etc/network/if-post-down.d",
    kind: "tree",
  },
  {
    path: p"etc/network/if-pre-down.d",
    kind: "tree",
  },
  {
    path: p"etc/network/if-pre-up.d",
    kind: "tree",
  },
  {
    path: p"etc/network/if-up.d",
    kind: "tree",
  },
  {
    path: p"etc/network/interfaces",
    kind: "file",
  },
  {
    path: p"usr/lib/xinit/services/net.xsh",
    kind: "file",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, error] {
  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/net.xsh", 0o644, parents: true, overwrite: true)?
  fs.install(p"interfaces", fp"{dest}/etc/network/interfaces", 0o644, parents: true, overwrite: true)?
  fs.mkdir(fp"{dest}/etc/network/if-pre-up.d")?
  fs.mkdir(fp"{dest}/etc/network/if-up.d")?
  fs.mkdir(fp"{dest}/etc/network/if-down.d")?
  fs.mkdir(fp"{dest}/etc/network/if-pre-down.d")?
  fs.mkdir(fp"{dest}/etc/network/if-post-down.d")?
}
