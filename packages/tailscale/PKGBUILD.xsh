##! Package recipe metadata and build operations.
use pm.util as pm_util
## Package recipe export.
export const name = "tailscale"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.104.2"

## Package recipe export.
export const rel = "2"

## Package recipe export.
export let deps = []

## Package runtime dependencies.
export const runtime_only_deps = ["ca-certificates", "iptables", "xinit"]

## Package recipe export.
export const mkdeps_host: List[Str] = []

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://distfiles.gentoo.org/distfiles/c7/tailscale-1.104.2.tar.gz => source",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "4c1c806e16507414a1459afcdc399f6a1323c21a1ac90f07bea0465fd8fd7e1d"}],
  },
  {
    source: p"https://distfiles.gentoo.org/distfiles/eb/tailscale-1.104.2-vendor.tar.xz => vendored",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "65b3998c67bc94755d568a4dbc6ca89241b5c907283ca5dec055daf4fb2c8aa3"}],
  },
  {
    source: p"https://go.dev/dl/go1.27.3.linux-GOARCH.tar.gz => go",
    kind: "auto",
    architectures: ["all"],
    checksums: [
      {arch: "aarch64", sha256: "a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49"},
      {arch: "x86_64", sha256: "65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40"},
    ],
  },
  {
    source: p"files/laputa_trust.go",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "SKIP"}],
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
export const nostrip = true

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

error TailscaleBuildError = SourceChanged(path: Str) | BuildFailed(message: Str)

proc patch_go(path_value: Path, original: Str, replacement: Str) [fs, error] {
  let contents = path_value.read_text()?
  guard original in contents and contents.replace(original, with: "").byte_len() + original.byte_len() == contents.byte_len() else {
    return Err(TailscaleBuildError.SourceChanged(path_value.display()))
  }
  path_value.write(bytes.from_text(contents.replace(original, with: replacement)))
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cwd = fs.cwd()?
  let go = fp"{cwd}/go/bin/go"
  let _ = fs.copy_tree(p"vendored/vendor", p"source/vendor", parents: true, overwrite: true)?
  fs.install(p"laputa_trust.go", p"go/src/crypto/tls/laputa_trust.go", 0o644, parents: true, overwrite: true)
  let handshake = p"go/src/crypto/tls/handshake_client.go"
  patch_go(handshake,
    "\tif session != nil {\n\t\tdefer func() {",
    "\tif session != nil {\n\t\tif err := laputaCheckPeer(session.peerCertificates, session.verifiedChains, c.config); err != nil {\n\t\t\treturn err\n\t\t}\n\t\tdefer func() {",
  )
  patch_go(handshake,
    "\tc.peerCertificates = certs\n",
    "\tif err := laputaCheckPeer(certs, c.verifiedChains, c.config); err != nil {\n\t\tc.sendAlert(alertBadCertificate)\n\t\treturn err\n\t}\n\n\tc.peerCertificates = certs\n",
  )
  let config = p"go/src/crypto/tls/common.go"
  patch_go(config,
    "\tInsecureSkipVerify bool\n",
    "\tInsecureSkipVerify bool\n\n\t// LaputaVerify checks system or extra roots before callbacks when a Laputa policy is present.\n\tLaputaVerify bool\n",
  )
  patch_go(config,
    "\t\tInsecureSkipVerify:                  c.InsecureSkipVerify,\n",
    "\t\tInsecureSkipVerify:                  c.InsecureSkipVerify,\n\t\tLaputaVerify:                        c.LaputaVerify,\n",
  )
  let tlsdial = p"source/net/tlsdial/tlsdial.go"
  patch_go(tlsdial,
    "\tconf.RootCAs = nil // we do our own verification in VerifyConnection\n",
    "",
  )
  patch_go(tlsdial,
    "\tconf.InsecureSkipVerify = true\n\tconf.VerifyConnection = func(cs tls.ConnectionState) (retErr error) {",
    "\tconf.InsecureSkipVerify = true\n\tconf.LaputaVerify = true\n\tconf.VerifyConnection = func(cs tls.ConnectionState) (retErr error) {",
  )
  let arch = pm_util.target_arch()?
  let goarch = if arch == "x86_64" { "amd64" } else { "arm64" }
  let flags = "-s -w -X tailscale.com/version.longStamp=1.104.2 -X tailscale.com/version.shortStamp=1.104.2 -X tailscale.com/version.gitCommitStamp=e26db7a5797683ec99ad1516c40b628c7f2dfd71"
  p"built".mkdir()
  let command = process.command_argv(
    go,
    [go.display(), "build", "-mod=vendor", "-buildvcs=false", "-trimpath", "-tags=xversion", "-ldflags", flags, "-o", fp"{cwd}/built".display(), "./cmd/tailscale", "./cmd/tailscaled"],
    fp"{cwd}/source",
    {PATH: e"PATH" ?? "", HOME: cwd.display(), GOCACHE: fp"{cwd}/go-cache".display(), GOPATH: fp"{cwd}/go-path".display(), GOTOOLCHAIN: "local", GOPROXY: "off", GOSUMDB: "off", CGO_ENABLED: "0", GOOS: "linux", GOARCH: goarch},
  )
  let status = process.run(command)?
  guard status.ok else {
    return Err(TailscaleBuildError.BuildFailed("go build failed"))
  }
  fs.install(p"built/tailscale", fp"{dest}/usr/bin/tailscale", 0o755, parents: true, overwrite: true)
  fs.install(p"built/tailscaled", fp"{dest}/usr/bin/tailscaled", 0o755, parents: true, overwrite: true)
  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/tailscaled.xsh", 0o644, parents: true, overwrite: true)

  fp"{dest}/var/lib/tailscale".mkdir()
  fp"{dest}/usr/lib/sysctl.d".mkdir()
  fp"{dest}/usr/lib/sysctl.d/50-tailscale-ipv6.conf".write(
    """net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
""",
  )
}
