##! DejaVu Sans font package.
use pm.types
## Package name.
export const name = "font-ttf-dejavu-sans"
## Package kind.
export const package_kind = "payload"
## Upstream version.
export const ver = "2.37"
## Package revision.
export const rel = "1"
## Runtime dependencies.
export let deps = []
## Build dependencies.
export let mkdeps_host = []
## Verified source archive.
export const upstream_sources = [
  {
    source: p"https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-sans-ttf-VERSION.zip",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "5c6e497a2f36552cb5ffb112c413a6af39c0f3c47653662b90b4fa6499822fd7"}],
  },
]
## Installed files.
export const filetree = [
  {path: p"usr/share/fonts/TTF/DejaVuSans.ttf", kind: "file"},
  {path: p"usr/share/licenses/font-ttf-dejavu-sans/LICENSE", kind: "file"},
]
## Install the font and its license.
export proc build(dest: Path) [fs, error] {
  let files = fs.walk(p".", gitignore: false)? |> where .kind == "file"
  let fonts = files |> where .name == "DejaVuSans.ttf"
  let licenses = files |> where .name == "LICENSE"
  guard fonts.len() == 1 and licenses.len() == 1 else {
    return Err(types.PmError.PackageContract("dejavu sans: expected one font and license"))
  }
  fs.install(fonts[0].path, fp"{dest}/usr/share/fonts/TTF/DejaVuSans.ttf", 0o644, parents: true, overwrite: true)
  fs.install(licenses[0].path, fp"{dest}/usr/share/licenses/font-ttf-dejavu-sans/LICENSE", 0o644, parents: true, overwrite: true)
}
