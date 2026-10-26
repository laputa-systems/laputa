##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "tailscale"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.104.2"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export let deps = []

## The build only installs the prebuilt static binaries and the service
## module; tailscaled drives iptables and runs under xinit at runtime.
export const runtime_only_deps = ["ca-certificates", "iptables", "xinit"]

## Package recipe export.
export const mkdeps_host: List[Str] = []

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://pkgs.tailscale.com/stable/tailscale_VERSION_GOARCH.tgz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "5776aaa901b5ef1916e66be5bb54b9f481cd399c9c28db123a8cab620efa237b",
      },
      {
        arch: "x86_64",
        sha256: "512f613ed7d04fc7282f7dc5bd76aa105aae28168fbb9357eb749ebcbc29f0ae",
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
        arch: "aarch64",
        sha256: "SKIP",
      },
      {
        arch: "x86_64",
        sha256: "SKIP",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/bin/tailscale",
    kind: "binary",
  },
  {
    path: p"usr/bin/tailscaled",
    kind: "binary",
  },
  {
    path: p"usr/lib/sysctl.d/50-tailscale-ipv6.conf",
    kind: "file",
  },
  {
    path: p"usr/lib/xinit/services/tailscaled.xsh",
    kind: "file",
  },
]

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  fs.install(p"tailscale", fp"{dest}/usr/bin/tailscale", 0o755, parents: true, overwrite: true)
  fs.install(p"tailscaled", fp"{dest}/usr/bin/tailscaled", 0o755, parents: true, overwrite: true)
  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/tailscaled.xsh", 0o644, parents: true, overwrite: true)

  fp"{dest}/var/lib/tailscale".mkdir()
  fp"{dest}/usr/lib/sysctl.d".mkdir()

  fp"{dest}/usr/lib/sysctl.d/50-tailscale-ipv6.conf".write(
    """net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
""",
  )
}
