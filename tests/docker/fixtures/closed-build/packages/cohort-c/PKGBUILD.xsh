##! Closed C payload package.
## Package name.
export const name = "cohort-c"
## Installable package kind.
export const package_kind = "payload"
## Package version.
export const ver = "1.0.0"
## Package release.
export const rel = "1"
## Runtime dependencies.
export let deps = []
## Build host dependencies.
export let mkdeps_host = []
## Build target dependencies.
export let mkdeps_target = []
## Repository source inputs.
export const upstream_sources = [{source: p"files", kind: "directory", architectures: ["all"], checksums: [{arch: "all", sha256: "SKIP"}]}]
## Preserve the compiler outputs.
export const nostrip = true
## Installed payload contract.
export const filetree = [{path: p"usr/bin/cohort-c", kind: "binary"}]

## Build the declared C payload.
export proc build(dest: Path) [fs, process, env, error] -> Result[Unit, Error] {
  run /seed/probe
  let source = env("XSH_PM_SOURCE_DIR")?
  fp"{dest}/usr/bin".mkdir()
  run /usr/bin/clang "-fuse-ld=/bin/mold" "-static" "-nostdlib" "/usr/lib/crt1.o" "/usr/lib/crti.o" fp"{source}/hello.c" "/usr/lib/libc.a" "/usr/lib/crtn.o" "-o" fp"{dest}/usr/bin/cohort-c"
}
