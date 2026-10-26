##! Closed XSH payload package.
## Package name.
export let name = "cohort-xsh"
## Installable package kind.
export let package_kind = "payload"
## Package version.
export let ver = "1.0.0"
## Package release.
export let rel = "1"
## Runtime dependencies.
export let deps = []
## Build host dependencies.
export let mkdeps_host = []
## Build target dependencies.
export let mkdeps_target = []
## Repository source inputs.
export let upstream_sources = []
## Preserve the compiler outputs.
export let nostrip = true
## Installed payload contract.
export let filetree = [{path: p"usr/share/cohort-xsh", kind: "file"}]

## Build the declared XSH payload.
export proc build(dest: Path) [fs, process, env, error] -> Result[Unit, Error] {
  fp"{dest}/usr/share".mkdir()?
  fp"{dest}/usr/share/cohort-xsh".write("declared XSH payload\n")?
}
