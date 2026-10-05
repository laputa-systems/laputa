##! Linux userspace API headers, built from the kernel source without building the kernel.
# Userland compiles against these headers only, so they are their own
# package: a kernel config or Kbuild change rebuilds `linux` alone, not every
# package whose build includes <linux/...> or <asm/...>.
## Package recipe export.
export const name = "linux-headers"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## The kernel release these headers come from; `linux` pins the same tarball.
export const ver = "7.2.9"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps: List[Str] = []

## Installing headers compiles nothing.
export const mkdeps_host: List[Str] = []

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.9.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b4c5dfbe51a364a6c7f03869200f88c8e1f77403539005f14b7fc6bc91b8d8ba",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [{path: p"usr/include", kind: "tree"}]

## The headers_install port runs in a child XSH process, as the `linux`
## recipe's Kbuild does, so this module stays plain recipe metadata for the
## PM loader.
export proc build(dest: Path) [process, env, error] {
  let recipe_dir = e"XSH_PM_RECIPE_DIR" ?? ""
  let xsh = process.which("xsh")?
  run $xsh fp"{recipe_dir}/PKGBUILD-build.xsh" "--" $dest ?
}
