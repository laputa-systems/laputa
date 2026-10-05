##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "xinit"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1"

## Package recipe export.
export const rel = "9"

## Package recipe export.
export let deps = []

## The build installs xinit.xsh; PID 1 runs it with `xsh`.
export const runtime_only_deps = ["xsh"]

## Package recipe export.
export let mkdeps_host = []

## Package recipe export.
## xinit lives in this monorepo; the executor stages it through
## XSH_PM_REPOSITORY_ROOT, and the recipe fingerprint hashes its content.
export const upstream_sources = [
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
export const nostrip = true

## Package recipe export.
export const filetree = [
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
  fs.install(p"xinit.xsh", xinit, 0o755, parents: true, overwrite: true)
  fp"{dest}/usr/bin/init".symlink(to: p"xinit")
  fp"{dest}/init".symlink(to: p"usr/bin/xinit")
}
