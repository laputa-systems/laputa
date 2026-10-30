##! Package recipe.
## Package recipe export.
export const name = "kache"
## Package recipe export.
export const package_kind = "payload"
## Package recipe export.
export const ver = "1.0.0"
## Package recipe export.
export const rel = "1"
## Package recipe export.
export const deps: List[Str] = []
## Package recipe export.
export const mkdeps_host: List[Str] = []
## Package recipe export.
export const nostrip = true
## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/kunobi-ninja/kache/releases/download/vVERSION/kache-ARCH-unknown-linux-musl.tar.gz",
    kind: "auto",
    architectures: ["all"],
    checksums: [
      {arch: "aarch64", sha256: "88abd848be7d300d4e30b8510ebdc45990dae3f96b6591e3498209639cf34701"},
      {arch: "x86_64", sha256: "756e9701a6afb8354fd8b1d76164e13272d320354d84f01197e57d8a3b4be397"},
    ],
  },
  {
    source: p"https://raw.githubusercontent.com/kunobi-ninja/kache/vVERSION/LICENSE",
    kind: "file",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "d7e2ce9dbb8d3b2e6550c93be4f434ae434e6e5aa9b88ee3af3896a903b1344e"}],
  },
]
## Package recipe export.
export const filetree = [
  {path: p"usr/bin/kache", kind: "binary"},
  {path: p"usr/share/licenses/kache/LICENSE", kind: "file"},
]
## Package recipe export.
export proc build(dest: Path) [fs, error] {
  fs.install(p"kache", fp"{dest}/usr/bin/kache", 0o755, parents: true, overwrite: true)
  fs.install(p"LICENSE", fp"{dest}/usr/share/licenses/kache/LICENSE", 0o644, parents: true, overwrite: true)
}
