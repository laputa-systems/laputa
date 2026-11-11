##! XSH module `xinfra` package and build operations.
## Package recipe export.
export const name = "xinfra"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "0.3.0"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export let deps = []

## The wrapper and every xinfra module run on the system `xsh`, whose built-in
## `ssh` module carries the transport; nothing is vendored.
export const runtime_only_deps = ["xsh"]

## Package recipe export.
export let mkdeps_host = []

## Package recipe export.
## xinfra is vendored into this monorepo as a top-level tree. The recipe addresses
## only the shipped subtrees as `repository/` sources, which the PM resolves
## against the checkout root and hashes into the plan fingerprint.
export const upstream_sources = [
  {
    source: p"repository/xinfra/bin => bin",
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
    source: p"repository/xinfra/lib => lib",
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
    source: p"repository/xinfra/docs => docs",
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
    source: p"repository/xinfra/examples => examples",
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
    source: p"repository/xinfra/README.md",
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
export const filetree = [
  {path: p"usr/bin/xinfra", kind: "file"},
  {path: p"usr/lib/xinfra/bin", kind: "tree"},
  {path: p"usr/lib/xinfra/lib", kind: "tree"},
  {path: p"usr/share/doc/xinfra/docs", kind: "tree"},
  {path: p"usr/share/doc/xinfra/examples", kind: "tree"},
  {path: p"usr/share/doc/xinfra/README.md", kind: "file"},
]

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  let _ = fs.copy_tree(p"bin", fp"{dest}/usr/lib/xinfra/bin", parents: true, overwrite: true)?
  let _ = fs.copy_tree(p"lib", fp"{dest}/usr/lib/xinfra/lib", parents: true, overwrite: true)?
  let _ = fs.copy_tree(p"docs", fp"{dest}/usr/share/doc/xinfra/docs", parents: true, overwrite: true)?
  let _ = fs.copy_tree(p"examples", fp"{dest}/usr/share/doc/xinfra/examples", parents: true, overwrite: true)?
  fs.install(p"README.md", fp"{dest}/usr/share/doc/xinfra/README.md", 0o644, parents: true, overwrite: true)
  fp"{dest}/usr/bin".mkdir()

  fp"{dest}/usr/bin/xinfra".write(
    """#!/bin/xsh
error WrapperError = Failed(message: Str)

proc main(...argv: List[Str]) [process, env, error] {
  let forwarded = ["/bin/xsh", "/usr/lib/xinfra/bin/xinfra.xsh", "--"].extend(argv)
  let status = process.run(
    process.command_argv(
      p"/bin/xsh",
      forwarded,
      p"/",
      {XSH_MODULE_PATH: "/usr/lib/xinfra/lib"},
    ),
  )?

  if ! status.ok {
    if status.exited() {
      exit status.exit_code()?
    }

    return Err(WrapperError.Failed("xinfra command was signaled"))
  }
}

main(@args)?
""",
    mode: 0o755,
  )
}
