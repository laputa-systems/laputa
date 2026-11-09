##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "play"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "0.43.2"

## Package recipe export.
export const rel = "1"

## Play publishes Linux releases for x86_64 musl only.
export const architectures = ["x86_64"]

## Runtime link inputs matching the release binary's DT_NEEDED entries.
export const deps = [
  "musl",
  "alsa-lib",
  "ffmpeg",
  "freetype",
  "harfbuzz",
  "rust-fontconfig",
  "vulkan-loader",
  "wayland-libs-client",
  "zlib",
]

## Subtitles and the on-screen controller look up a font at run time.
export const runtime_only_deps = ["font-ttf-dejavu-sans"]

## Package recipe export.
export const mkdeps_host: List[Str] = []

## The release links the shared FFmpeg runtime that the ffmpeg package installs in /usr/lib.
export const upstream_sources = [
  {
    source: p"https://github.com/joshuarli/play/releases/download/vVERSION/player-x86_64-linux-musl.tar.gz",
    kind: "auto",
    architectures: [
      "x86_64",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "1b259f2cd1bf55b130eeb79535a7223fc6a8c23b26c9ef7af5177110f97272c1",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {path: p"usr/bin/player", kind: "binary"},
]

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  fs.install(p"player", fp"{dest}/usr/bin/player", 0o755, parents: true, overwrite: true)
}
