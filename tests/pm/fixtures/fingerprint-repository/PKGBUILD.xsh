##! Semantic fingerprint package fixture with an in-tree repository source.
## Package name.
export let name = "fingerprint-repository"
## Explicit package classification.
export let package_kind = "payload"
## Package version.
export let ver = "1.0.0"
## Package release.
export let rel = "1"
## Runtime dependencies.
export let deps = []
## Host build dependencies.
export let mkdeps_host = []
## Target build dependencies.
export let mkdeps_target = []
## Declared in-tree source: the test provides repository/tool under its root.
export let upstream_sources = [{source: p"repository/tool", kind: "auto", architectures: ["all"], checksums: [{arch: "all", sha256: "SKIP"}]}]
## Declared payload files.
export let filetree = []
## Builds the fixture payload.
export proc build(dest: Path) [fs, error] {
  dest.mkdir()?
}
