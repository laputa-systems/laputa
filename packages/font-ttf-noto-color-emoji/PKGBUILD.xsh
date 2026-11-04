##! Optional Noto Color Emoji font package.
use pm.types

## Package name.
export const name = "font-ttf-noto-color-emoji"
## Package kind.
export const package_kind = "payload"
## Upstream release date.
export const ver = "2026.09.24"
## Package revision.
export const rel = "1"
## Runtime dependencies.
export let deps = []
## Build dependencies.
export let mkdeps_host = []
## Verified upstream font and license.
export const upstream_sources = [
  {
    source: p"https://raw.githubusercontent.com/googlefonts/noto-emoji/e20cbc2bbec1926686be9f9bee7d1d2cfa1fea0e/2D/fonts/NotoColorEmoji.ttf",
    kind: "file",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "15671215ab769fdc7162a045d56fd7d7e477c51b04e6b3c761d914d8fdd6cc44"}],
  },
  {
    source: p"https://raw.githubusercontent.com/googlefonts/noto-emoji/e20cbc2bbec1926686be9f9bee7d1d2cfa1fea0e/2D/fonts/LICENSE",
    kind: "file",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"}],
  },
]
## Installed files.
export const filetree = [
  {path: p"usr/share/fonts/TTF/NotoColorEmoji.ttf", kind: "file"},
  {path: p"usr/share/licenses/font-ttf-noto-color-emoji/LICENSE", kind: "file"},
]
## Install the font and license.
export proc build(dest: Path) [fs, error] {
  let files = fs.walk(p".", gitignore: false)? |> where .kind == "file"
  let fonts = files |> where .name == "NotoColorEmoji.ttf"
  let licenses = files |> where .name == "LICENSE"
  guard fonts.len() == 1 and licenses.len() == 1 else {
    return Err(types.PmError.PackageContract("noto color emoji: expected one font and license"))
  }
  fs.install(fonts[0].path, fp"{dest}/usr/share/fonts/TTF/NotoColorEmoji.ttf", 0o644, parents: true, overwrite: true)
  fs.install(licenses[0].path, fp"{dest}/usr/share/licenses/font-ttf-noto-color-emoji/LICENSE", 0o644, parents: true, overwrite: true)
}
