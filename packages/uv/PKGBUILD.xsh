##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "uv"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "0.12.23"

## Package recipe export.
export const rel = "1"

## The upstream release binaries are static-pie musl executables, so the
## package needs no libraries at runtime.
export const deps: List[Str] = []

## Package recipe export.
export const mkdeps_host: List[Str] = []

# Astral's official static musl release archives; each holds one directory
# with the `uv` and `uvx` executables, which source staging strips.
## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/astral-sh/uv/releases/download/VERSION/uv-ARCH-unknown-linux-musl.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "b536543cc4d50661986b165c76ee8aa9056e4fa332edcd153ff2e98760f9359b",
      },
      {
        arch: "x86_64",
        sha256: "1cff8783850e794470aadb73f54b749542a511fc57b0ce6468b64bd3852e0ade",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/bin/uv",
    kind: "binary",
  },
  {
    path: p"usr/bin/uvx",
    kind: "binary",
  },
]

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  fs.install(p"uv", fp"{dest}/usr/bin/uv", 0o755, parents: true, overwrite: true)?
  fs.install(p"uvx", fp"{dest}/usr/bin/uvx", 0o755, parents: true, overwrite: true)?
}
