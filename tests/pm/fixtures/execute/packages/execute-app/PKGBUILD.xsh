##! Executor fixture that requires both runtime and build-host dependency roots.
## Package name.
export let name = "execute-app"
## Payload kind.
export let package_kind = "payload"
## Package version.
export let ver = "1.0.0"
## Package release.
export let rel = "1"
## Runtime dependency.
export let deps = ["execute-dep"]
## Build-host dependency.
export let mkdeps_host = ["execute-tool"]
## No build-target dependencies.
export let mkdeps_target = []
## No upstream source inputs.
export let upstream_sources = []
## Declared output.
export let filetree = [{path: p"usr/share/execute-app.txt", kind: "file"}]

## Builds the application after both dependency roots are available.
## Target files resolve through LAPUTA_ROOT and build tools through XSH_PM_BUILD_ROOT.
export proc build(dest: Path) [fs, env, error] -> Result[Unit, Error] {
  let root = env("LAPUTA_ROOT")?
  let build_root = env("XSH_PM_BUILD_ROOT")?
  let _ = fp"{root}/usr/share/execute-dep.txt".read_text()?
  let _ = fp"{build_root}/usr/share/execute-tool.txt".read_text()?

  let target = fp"{dest}/usr/share/execute-app.txt"
  target.parent.mkdir()?
  target.write("application v1\n")?
}
