##! Optional Noto Sans thai font package.
use pm.types

## Package name.
export const name = "font-ttf-noto-sans-thai"
## Package kind.
export const package_kind = "payload"
## Upstream font version.
export const ver = "2.002"
## Package revision.
export const rel = "1"
## Runtime dependencies.
export let deps = []
## Build dependencies.
export let mkdeps_host = []
## Verified upstream font and license.
export const upstream_sources = [
  {source: p"https://raw.githubusercontent.com/google/fonts/2fe1e8c6b137fb13041a7cfca6fdcd8a910ea4dc/ofl/notosansthai/NotoSansThai%5Bwdth%2Cwght%5D.ttf => font", kind: "file", architectures: ["all"], checksums: [{arch: "all", sha256: "5a1c559bb539583c8a1fd99d1c5b9491e5e14478c9cd2bd0970d5c3096cc9ef8"}]},
  {source: p"https://raw.githubusercontent.com/google/fonts/2fe1e8c6b137fb13041a7cfca6fdcd8a910ea4dc/ofl/notosansthai/OFL.txt => license", kind: "file", architectures: ["all"], checksums: [{arch: "all", sha256: "2e98fd23a52d253db8612cd5942c8f2ff4111b21d2367050fdca91d8ccc374a0"}]},
]
## Installed files.
export const filetree = [
  {path: p"usr/share/fonts/TTF/NotoSansThai.ttf", kind: "file"},
  {path: p"usr/share/licenses/font-ttf-noto-sans-thai/OFL.txt", kind: "file"},
]
## Install the font and license.
export proc build(dest: Path) [fs, error] {
  let fonts = fs.walk(p"font", gitignore: false)? |> where .kind == "file" and .ext == "ttf"
  guard fonts.len() == 1 else {
    return Err(types.PmError.PackageContract("font-ttf-noto-sans-thai: expected one font"))
  }
  fs.install(fonts[0].path, fp"{dest}/usr/share/fonts/TTF/NotoSansThai.ttf", 0o644, parents: true, overwrite: true)
  fs.install(p"license/OFL.txt", fp"{dest}/usr/share/licenses/font-ttf-noto-sans-thai/OFL.txt", 0o644, parents: true, overwrite: true)
}
