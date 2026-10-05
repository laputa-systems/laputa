##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "m4"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.0"

## Package recipe export.
export const rel = "11"

## Package recipe export.
export const deps: List[Str] = []

## Package recipe export.
export let mkdeps_host = []

## `/usr/bin/m4` is an XSH script; it needs the `xsh` runner at runtime.
export const runtime_only_deps = ["xsh"]

# m4 is implemented in pure XSH — no tarball, no compilation.
## Package recipe export.
export const upstream_sources = [
  {
    source: p"files/m4.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [{path: p"usr/bin/m4", kind: "file"}]

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  fs.install(p"m4.xsh", fp"{dest}/usr/bin/m4", 0o755, parents: true, overwrite: true)
}
