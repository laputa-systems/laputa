##! Optional Noto Sans CJK Simplified Chinese font package.
use pm.types

## Package name.
export const name = "font-otf-noto-sans-cjk-sc"
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
  {source: p"https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf => font", kind: "file", architectures: ["all"], checksums: [{arch: "all", sha256: "2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b"}]},
  {source: p"https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/LICENSE => license", kind: "file", architectures: ["all"], checksums: [{arch: "all", sha256: "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"}]},
]
## Installed files.
export const filetree = [
  {path: p"usr/share/fonts/OTF/NotoSansCJKsc-Regular.otf", kind: "file"},
  {path: p"usr/share/licenses/font-otf-noto-sans-cjk-sc/LICENSE", kind: "file"},
]
## Install the font and license.
export proc build(dest: Path) [fs, error] {
  let fonts = fs.walk(p"font", gitignore: false)? |> where .kind == "file" and .ext == "otf"
  guard fonts.len() == 1 else {
    return Err(types.PmError.PackageContract("noto sans cjk sc: expected one font"))
  }
  fs.install(fonts[0].path, fp"{dest}/usr/share/fonts/OTF/NotoSansCJKsc-Regular.otf", 0o644, parents: true, overwrite: true)
  fs.install(p"license/LICENSE", fp"{dest}/usr/share/licenses/font-otf-noto-sans-cjk-sc/LICENSE", 0o644, parents: true, overwrite: true)
}
