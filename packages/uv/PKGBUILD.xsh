##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "uv"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "0.13.4"

## Package recipe export.
export const rel = "1"

## The upstream release binaries are static-pie musl executables, so the
## package needs no libraries at runtime.
export const deps: List[Str] = []

## Dependencies installed only in the runtime closure.
export const runtime_only_deps = ["ca-certificates"]

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
        sha256: "253a17cadcb659ae77a0fe3b9a2f1c14297528d480c421899e61e64d64f24e8f",
      },
      {
        arch: "x86_64",
        sha256: "28d4385f9f9d1d1c7654d85b3855e0e2615b2f6cc13136a2edff858bbdc16ff1",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"etc/uv/uv.toml",
    kind: "file",
  },
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
  fs.install(p"uv", fp"{dest}/usr/bin/uv", 0o755, parents: true, overwrite: true)
  fs.install(p"uvx", fp"{dest}/usr/bin/uvx", 0o755, parents: true, overwrite: true)
  fp"{dest}/etc/uv".mkdir()
  fp"{dest}/etc/uv/uv.toml".write("system-certs = true\n")
}
