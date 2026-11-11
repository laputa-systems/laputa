##! Closed-build hostile read package: an undeclared host read must fail under confinement.
## Package name.
export let name = "cohort-hostile-read"
## Installable package kind.
export let package_kind = "payload"
## Package version.
export let ver = "1.0.0"
## Package release.
export let rel = "1"
## No runtime dependencies.
export let deps = []
## No build host dependencies.
export let mkdeps_host = []
## No build target dependencies.
export let mkdeps_target = []
## No upstream sources.
export let upstream_sources = []
## Preserve the outputs.
export let nostrip = true
## Installed payload contract.
export let filetree = [{path: p"usr/share/cohort-hostile-read", kind: "file"}]

error Escape = Failed(message: Str)

## The cohort checkout is outside every declared read root, so reading it must be denied.
export proc build(dest: Path) [fs, process, env, error] -> Result[Unit, Error] {
  let undeclared = p"/cohort/build.xsh"
  match undeclared.read_text() {
    Ok(_) => Err(Escape.Failed("undeclared read succeeded; the build ran unconfined"))
    Err(problem) => {
      if "Permission denied" not in problem.message {
        return Err(Escape.Failed(f"undeclared read failed unexpectedly: {problem.message}"))
      }
      Err(Escape.Failed(f"undeclared read denied by confinement: {problem.message}"))
    }
  }
}
