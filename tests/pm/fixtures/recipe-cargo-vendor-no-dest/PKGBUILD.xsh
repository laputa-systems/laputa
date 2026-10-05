##! A crate set with no destination directory.
## Package name.
export let name = "recipe-cargo-vendor-no-dest"
## Package kind.
export let package_kind = "payload"
## Package version.
export let ver = "1.0.0"
## Package release.
export let rel = "1"
## Runtime dependencies.
export let deps = []
## Build-host dependencies.
export let mkdeps_host = []
## A Cargo.lock staged without `=> DIR`.
export let upstream_sources = [{
  source: p"files/Cargo.lock",
  kind: "cargo-vendor",
  architectures: ["all"],
  checksums: [{arch: "all", sha256: "SKIP"}],
}]
## No payload files.
export let filetree = []

## Build nothing.
export proc build(dest: Path) [fs, error] {
  dest.mkdir()?
}
