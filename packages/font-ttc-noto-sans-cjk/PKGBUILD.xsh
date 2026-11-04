##! Optional Noto Sans CJK font collection package.
use pm.types

## Package name.
export const name = "font-ttc-noto-sans-cjk"
## Package kind.
export const package_kind = "payload"
## Upstream font version.
export const ver = "2.004"
## Package revision.
export const rel = "1"
## Runtime dependencies.
export let deps = []
## Build dependencies.
export let mkdeps_host = []
## Verified upstream font and license.
export const upstream_sources = [
  {source: p"https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/OTC/NotoSansCJK-Regular.ttc => font", kind: "file", architectures: ["all"], checksums: [{arch: "all", sha256: "b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a"}]},
  {source: p"https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/LICENSE => license", kind: "file", architectures: ["all"], checksums: [{arch: "all", sha256: "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"}]},
]
## Installed files.
export const filetree = [
  {path: p"usr/share/fonts/TTF/NotoSansCJK-Regular.ttc", kind: "file"},
  {path: p"usr/share/licenses/font-ttc-noto-sans-cjk/LICENSE", kind: "file"},
]
## Install the font and license.
export proc build(dest: Path) [fs, error] {
  let fonts = fs.walk(p"font", gitignore: false)? |> where .kind == "file" and .ext == "ttc"
  guard fonts.len() == 1 else {
    return Err(types.PmError.PackageContract("noto sans cjk: expected one collection"))
  }
  fs.install(fonts[0].path, fp"{dest}/usr/share/fonts/TTF/NotoSansCJK-Regular.ttc", 0o644, parents: true, overwrite: true)
  fs.install(p"license/LICENSE", fp"{dest}/usr/share/licenses/font-ttc-noto-sans-cjk/LICENSE", 0o644, parents: true, overwrite: true)
}
