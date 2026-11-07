##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "ffmpeg"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "9.0.2"

## Package recipe export.
export const rel = "2"

## The ffmpeg-build runtime archive links libavutil against the system VA-API
## libraries (libva and libva-drm, both shipped by libva) and nothing else
## outside itself.
export const deps = ["musl", "libva"]

## Package recipe export.
export const mkdeps_host: List[Str] = []

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/laputa-systems/ffmpeg-build/releases/download/20261107/ffmpeg-VERSION+20261107-ARCH-unknown-linux-musl-runtime.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "UNPUBLISHED-RUNTIME-RELEASE-PIN-AARCH64",
      },
      {
        arch: "x86_64",
        sha256: "UNPUBLISHED-RUNTIME-RELEASE-PIN-X86_64",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {path: p"usr/bin/ffmpeg", kind: "binary"},
  {path: p"usr/bin/ffprobe", kind: "binary"},
  {path: p"usr/lib/libavcodec.so", kind: "symlink"},
  {path: p"usr/lib/libavcodec.so.63", kind: "symlink"},
  {path: p"usr/lib/libavcodec.so.63.1.102", kind: "binary"},
  {path: p"usr/lib/pkgconfig/libavcodec.pc", kind: "file"},
  {path: p"usr/include/libavcodec", kind: "tree"},
  {path: p"usr/lib/libavformat.so", kind: "symlink"},
  {path: p"usr/lib/libavformat.so.63", kind: "symlink"},
  {path: p"usr/lib/libavformat.so.63.1.102", kind: "binary"},
  {path: p"usr/lib/pkgconfig/libavformat.pc", kind: "file"},
  {path: p"usr/include/libavformat", kind: "tree"},
  {path: p"usr/lib/libavfilter.so", kind: "symlink"},
  {path: p"usr/lib/libavfilter.so.12", kind: "symlink"},
  {path: p"usr/lib/libavfilter.so.12.1.102", kind: "binary"},
  {path: p"usr/lib/pkgconfig/libavfilter.pc", kind: "file"},
  {path: p"usr/include/libavfilter", kind: "tree"},
  {path: p"usr/lib/libavutil.so", kind: "symlink"},
  {path: p"usr/lib/libavutil.so.61", kind: "symlink"},
  {path: p"usr/lib/libavutil.so.61.1.102", kind: "binary"},
  {path: p"usr/lib/pkgconfig/libavutil.pc", kind: "file"},
  {path: p"usr/include/libavutil", kind: "tree"},
  {path: p"usr/lib/libswresample.so", kind: "symlink"},
  {path: p"usr/lib/libswresample.so.7", kind: "symlink"},
  {path: p"usr/lib/libswresample.so.7.1.102", kind: "binary"},
  {path: p"usr/lib/pkgconfig/libswresample.pc", kind: "file"},
  {path: p"usr/include/libswresample", kind: "tree"},
  {path: p"usr/lib/libswscale.so", kind: "symlink"},
  {path: p"usr/lib/libswscale.so.10", kind: "symlink"},
  {path: p"usr/lib/libswscale.so.10.1.102", kind: "binary"},
  {path: p"usr/lib/pkgconfig/libswscale.pc", kind: "file"},
  {path: p"usr/include/libswscale", kind: "tree"},
  {path: p"usr/share/licenses/ffmpeg/COPYING.LGPLv2.1", kind: "file"},
  {path: p"usr/share/licenses/ffmpeg/CREDITS", kind: "file"},
  {path: p"usr/share/licenses/ffmpeg/LICENSE.md", kind: "file"},
  {path: p"usr/share/licenses/ffmpeg/dav1d/COPYING", kind: "file"},
  {path: p"usr/share/licenses/ffmpeg/zlib/LICENSE", kind: "file"},
]

const libraries = [
  {name: "libavcodec", major: "63", version: "63.1.102"},
  {name: "libavformat", major: "63", version: "63.1.102"},
  {name: "libavfilter", major: "12", version: "12.1.102"},
  {name: "libavutil", major: "61", version: "61.1.102"},
  {name: "libswresample", major: "7", version: "7.1.102"},
  {name: "libswscale", major: "10", version: "10.1.102"},
]

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  fs.install(p"bin/ffmpeg", fp"{dest}/usr/bin/ffmpeg", 0o755, parents: true, overwrite: true)
  fs.install(p"bin/ffprobe", fp"{dest}/usr/bin/ffprobe", 0o755, parents: true, overwrite: true)
  let libdir = fp"{dest}/usr/lib"
  for library in libraries {
    let versioned = f"{library.name}.so.{library.version}"
    fs.install(fp"lib/{versioned}", fp"{libdir}/{versioned}", 0o755, parents: true, overwrite: true)
    fp"{libdir}/{library.name}.so.{library.major}".symlink(to: fp"{versioned}")
    fp"{libdir}/{library.name}.so".symlink(to: fp"{library.name}.so.{library.major}")
    fs.install(fp"lib/pkgconfig/{library.name}.pc", fp"{libdir}/pkgconfig/{library.name}.pc", 0o644, parents: true, overwrite: true)
    let _ = fs.copy_tree(fp"include/{library.name}", fp"{dest}/usr/include/{library.name}", parents: true, overwrite: true)?
  }
  let licenses = fp"{dest}/usr/share/licenses/ffmpeg"
  for file in ["COPYING.LGPLv2.1", "CREDITS", "LICENSE.md"] {
    fs.install(fp"share/licenses/ffmpeg/{file}", fp"{licenses}/{file}", 0o644, parents: true, overwrite: true)
  }
  fs.install(p"share/licenses/dav1d/COPYING", fp"{licenses}/dav1d/COPYING", 0o644, parents: true, overwrite: true)
  fs.install(p"share/licenses/zlib/LICENSE", fp"{licenses}/zlib/LICENSE", 0o644, parents: true, overwrite: true)
}
