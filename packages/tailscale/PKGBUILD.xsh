##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "tailscale"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.102.4"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export let deps = []

## The build only installs the prebuilt static binaries and the service
## module; tailscaled drives iptables and runs under xinit at runtime.
export const runtime_only_deps = ["iptables", "xinit"]

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
        sha256: "9dd1e6a592a014bbaea0103167ffe299adeda4ba14e078ce9c2895364f6c4c3f",
      },
      {
        arch: "x86_64",
        sha256: "50748df1045e60b5b695f19f4c56b0da36c019948b440fb456b6584a50f0d8b9",
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

  # Persistent state survives reboots on the root filesystem.
  fs.mkdir(fp"{dest}/var/lib/tailscale")
  fs.mkdir(fp"{dest}/usr/lib/sysctl.d")

  fs.write(
    fp"{dest}/usr/lib/sysctl.d/50-tailscale-ipv6.conf",
    """net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
""",
  )
}
