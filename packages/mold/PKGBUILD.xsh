##! Package recipe.
## Package recipe export.
export const name = "mold"
## Package recipe export.
export const package_kind = "payload"
## Package recipe export.
export const ver = "3.0.0"
## Package recipe export.
export const rel = "1"
## Package recipe export.
export const deps: List[Str] = []
## Package recipe export.
export const mkdeps_host: List[Str] = []
## Package recipe export.
export const nostrip = true
## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/rui314/mold/releases/download/vVERSION/mold-VERSION-ARCH-linux.tar.gz",
    kind: "auto",
    architectures: ["all"],
    checksums: [
      {arch: "aarch64", sha256: "52c759d3689babaea4c42af2f31062a74ab83e17ffb5a8090232534c67b70577"},
      {arch: "x86_64", sha256: "6c90d4a474c7c0409dfb575be03a5345878ac14fdba18de8b40fa58c60121189"},
    ],
  },
]
## Package recipe export.
export const filetree = [
  {path: p"usr/bin/mold", kind: "binary"},
  {path: p"usr/bin/ld.mold", kind: "symlink"},
  {path: p"usr/libexec/mold/ld", kind: "symlink"},
  {path: p"usr/share/licenses/mold/LICENSE", kind: "file"},
]
## Package recipe export.
export proc build(dest: Path) [fs, error] {
  fs.install(p"bin/mold", fp"{dest}/usr/bin/mold", 0o755, parents: true, overwrite: true)
  fs.install(p"share/doc/mold/LICENSE", fp"{dest}/usr/share/licenses/mold/LICENSE", 0o644, parents: true, overwrite: true)
  fp"{dest}/usr/bin/ld.mold".symlink(to: p"mold")
  fp"{dest}/usr/libexec/mold".mkdir(parents: true)
  fp"{dest}/usr/libexec/mold/ld".symlink(to: p"../../bin/mold")
}
