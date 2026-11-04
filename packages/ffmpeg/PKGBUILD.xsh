##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "ffmpeg"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "9.0.2"

## Package recipe export.
export const rel = "1"

## The ffmpeg-build tools archive holds static-pie musl executables with no
## NEEDED entries, so the package needs no libraries at runtime.
export const deps: List[Str] = []

## Package recipe export.
export const mkdeps_host: List[Str] = []

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/laputa-systems/ffmpeg-build/releases/download/20261104/ffmpeg-VERSION+20261104-ARCH-unknown-linux-musl-tools.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "09d0b499a4703758a00f5ef134c3a0301302f85e8968b8d61718f7c49769d3de",
      },
      {
        arch: "x86_64",
        sha256: "882bae342d15b719eb940d11924d28f04c227eaffdf61e75449158190b8770f4",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {path: p"usr/bin/ffmpeg", kind: "binary"},
  {path: p"usr/bin/ffprobe", kind: "binary"},
  {path: p"usr/share/licenses/ffmpeg/COPYING.LGPLv2.1", kind: "file"},
  {path: p"usr/share/licenses/ffmpeg/CREDITS", kind: "file"},
  {path: p"usr/share/licenses/ffmpeg/LICENSE.md", kind: "file"},
  {path: p"usr/share/licenses/ffmpeg/dav1d/COPYING", kind: "file"},
  {path: p"usr/share/licenses/ffmpeg/zlib/LICENSE", kind: "file"},
]

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  fs.install(p"bin/ffmpeg", fp"{dest}/usr/bin/ffmpeg", 0o755, parents: true, overwrite: true)
  fs.install(p"bin/ffprobe", fp"{dest}/usr/bin/ffprobe", 0o755, parents: true, overwrite: true)
  let licenses = fp"{dest}/usr/share/licenses/ffmpeg"
  for file in ["COPYING.LGPLv2.1", "CREDITS", "LICENSE.md"] {
    fs.install(fp"share/licenses/ffmpeg/{file}", fp"{licenses}/{file}", 0o644, parents: true, overwrite: true)
  }
  fs.install(p"share/licenses/dav1d/COPYING", fp"{licenses}/dav1d/COPYING", 0o644, parents: true, overwrite: true)
  fs.install(p"share/licenses/zlib/LICENSE", fp"{licenses}/zlib/LICENSE", 0o644, parents: true, overwrite: true)
}
