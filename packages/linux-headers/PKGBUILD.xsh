##! Linux userspace API headers, built from the kernel source without building the kernel.
# Userland compiles against these headers only, so they are their own
# package: a kernel config or Kbuild change rebuilds `linux` alone, not every
# package whose build includes <linux/...> or <asm/...>.
## Package recipe export.
export const name = "linux-headers"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## The kernel release these headers come from; `linux` pins the same tarball.
export const ver = "7.0.5"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps: List[Str] = []

## Installing headers compiles nothing.
export const mkdeps_host: List[Str] = []

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.5.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "965fb0a1c1675399fc60c6063b227c0523041b5f9a662b66462f1212c438ac3c",
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
  let recipe_dir = env.get("XSH_PM_RECIPE_DIR") ?? ""
  let xsh = process.which("xsh")?
  run $xsh fp"{recipe_dir}/PKGBUILD-build.xsh" "--" $dest ?
}
