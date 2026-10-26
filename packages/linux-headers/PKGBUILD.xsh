##! Linux userspace API headers, built from the kernel source without building the kernel.
use packages.upstream_pins as upstream_pins
## Package recipe export.
export const name = "linux-headers"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## The kernel release these headers come from; `linux` pins the same tarball.
export const ver = upstream_pins.linux_kernel_version

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps: List[Str] = []

## Installing headers compiles nothing.
export const mkdeps_host: List[Str] = []

## Package recipe export.
export let upstream_sources = [upstream_pins.linux_kernel_source]

## Package recipe export.
export const filetree = [{path: p"usr/include", kind: "tree"}]

## The headers_install port runs in a child XSH process, as the `linux`
## recipe's Kbuild does, so this module stays plain recipe metadata for the
## PM loader.
export proc build(dest: Path) [process, env, error] {
  let recipe_dir = e"XSH_PM_RECIPE_DIR" ?? ""
  let xsh = process.which("xsh")?
  run $xsh fp"{recipe_dir}/PKGBUILD-build.xsh" "--" $dest
}
