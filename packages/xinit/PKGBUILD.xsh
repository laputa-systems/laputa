##! Package recipe metadata and build operations.
## Package recipe export.
export let name = "xinit"

## Explicit payload or metapackage classification.
export let package_kind = "payload"

## Package recipe export.
export let ver = "1"

## Package recipe export.
export let rel = "9"

## Package recipe export.
export let deps = []

## The build installs xinit.xsh; PID 1 runs it with `xsh`.
export let runtime_only_deps = ["xsh"]

## Package recipe export.
export let mkdeps_host = []

## Package recipe export.
## xinit lives in this monorepo; the executor stages it through
## XSH_PM_REPOSITORY_ROOT, and the recipe fingerprint hashes its content.
export let upstream_sources = [
  {
    source: p"repository/xinit/xinit.xsh",
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

## Package recipe export.
export let nostrip = true

## Package recipe export.
export let filetree = [
  {
    path: p"init",
    kind: "symlink",
  },
  {
    path: p"usr/bin/init",
    kind: "symlink",
  },
  {
    path: p"usr/bin/xinit",
    kind: "file",
  },
]

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  let xinit = fp"{dest}/usr/bin/xinit"
  fs.install(p"xinit.xsh", xinit, 0o755, parents: true, overwrite: true)?
  fs.symlink(p"xinit", fp"{dest}/usr/bin/init")?
  fs.symlink(p"usr/bin/xinit", fp"{dest}/init")?
}
