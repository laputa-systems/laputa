##! Optional Noto Sans devanagari font package.
use pm.types

## Package name.
export const name = "font-ttf-noto-sans-devanagari"
## Package kind.
export const package_kind = "payload"
## Upstream snapshot.
export const ver = "2026.11.04"
## Package revision.
export const rel = "1"
## Runtime dependencies.
export let deps = []
## Build dependencies.
export let mkdeps_host = []
## Verified upstream font and license.
export const upstream_sources = [
  {source: p"https://raw.githubusercontent.com/google/fonts/2fe1e8c6b137fb13041a7cfca6fdcd8a910ea4dc/ofl/notosansdevanagari/NotoSansDevanagari%5Bwdth%2Cwght%5D.ttf => font", kind: "file", architectures: ["all"], checksums: [{arch: "all", sha256: "14ec4af41f27482216d1c2229f417ff9b1425e1babb014e57d1d40d03229853e"}]},
  {source: p"https://raw.githubusercontent.com/google/fonts/2fe1e8c6b137fb13041a7cfca6fdcd8a910ea4dc/ofl/notosansdevanagari/OFL.txt => license", kind: "file", architectures: ["all"], checksums: [{arch: "all", sha256: "a216f6f8d85c7228093e0ee5e258d9d377e6671f68acb4db1930b29583d0f331"}]},
]
## Installed files.
export const filetree = [
  {path: p"usr/share/fonts/TTF/NotoSansDevanagari.ttf", kind: "file"},
  {path: p"usr/share/licenses/font-ttf-noto-sans-devanagari/OFL.txt", kind: "file"},
]
## Install the font and license.
export proc build(dest: Path) [fs, error] {
  let fonts = fs.walk(p"font", gitignore: false)? |> where .kind == "file" and .ext == "ttf"
  guard fonts.len() == 1 else {
    return Err(types.PmError.PackageContract("font-ttf-noto-sans-devanagari: expected one font"))
  }
  fs.install(fonts[0].path, fp"{dest}/usr/share/fonts/TTF/NotoSansDevanagari.ttf", 0o644, parents: true, overwrite: true)
  fs.install(p"license/OFL.txt", fp"{dest}/usr/share/licenses/font-ttf-noto-sans-devanagari/OFL.txt", 0o644, parents: true, overwrite: true)
}
