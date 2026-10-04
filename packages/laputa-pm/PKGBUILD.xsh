##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export const name = "laputa-pm"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1"

## Exported declaration `rel`.
export const rel = "15"

## Exported declaration `deps`.
export let deps = []

## The build installs PM sources and an XSH wrapper; both need `xsh` at runtime.
export const runtime_only_deps = ["xsh"]

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

## Exported declaration `upstream_sources`.
## The package manager is an explicit repository input. The executor stages
## this declared root through XSH_PM_REPOSITORY_ROOT before the recipe is
## isolated, so package builds never depend on `../../` traversal.
export const upstream_sources = [
  {
    source: p"repository/pm.xsh",
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
    source: p"repository/pm => pm",
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
## PM's module set changes as PM evolves, so the modules ship as one tree.
export const filetree = [
  {path: p"usr/bin/pm", kind: "file"},
  {path: p"usr/lib/pm/pm.xsh", kind: "file"},
  {path: p"usr/lib/pm/pm", kind: "tree"},
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, error] {
  fs.install(p"pm.xsh", fp"{dest}/usr/lib/pm/pm.xsh", 0o644, parents: true, overwrite: true)?
  let _ = fs.copy_tree(p"pm", fp"{dest}/usr/lib/pm/pm", parents: true, overwrite: true)?
  fs.mkdir(fp"{dest}/usr/bin")?

  fs.write(
    fp"{dest}/usr/bin/pm",
    """#!/bin/xsh
error WrapperError = Failed(message: Str)

proc main(...argv: List[Str]) [process, env, error] {
  let forwarded = ["/bin/xsh", "/usr/lib/pm/pm.xsh", "--"].extend(argv)
  let status = process.run(
    process.command_argv(
      /bin/xsh,
      forwarded,
      /,
      {XSH_MODULE_PATH: "/usr/lib/pm"},
    ),
  )?

  if ! status.ok {
    if status.exited() {
      abort(status.exit_code()?)
    }

    return Err(WrapperError.Failed("pm command was signaled"))
  }
}

main(@args)?
""",
  )?
  fs.chmod(fp"{dest}/usr/bin/pm", 0o755)?
}
