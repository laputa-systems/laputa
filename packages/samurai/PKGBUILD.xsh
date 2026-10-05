##! Package recipe metadata and build operations.
use pm.make

## Package recipe export.
export const name = "samurai"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.3"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/michaelforney/samurai/releases/download/VERSION/samurai-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "1bc020a9e133432df51911ac71cc34322f828934d9a2282ba2916d88c15976af",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [{path: p"usr/bin/ninja", kind: "symlink"}, {path: p"usr/bin/samu", kind: "binary"}]

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let os = system.uname()?
  let triple = f"{os.machine}-linux-musl"

  # samurai has a simple hand-written Makefile; compile all .c files directly.
  # Source list and flags from the Makefile's OBJ and ALL_CFLAGS, with OS=posix.
  # Its LDLIBS=-lrt is omitted: musl's librt is an empty stub.
  let cflags = ["-std=c99", "-Wall", "-Wextra", "-Wshadow", "-Wmissing-prototypes", "-Wpedantic", "-Wno-unused-parameter"]

  let samu = make.c_program(
    {
      cc,
      triple,
      cflags,
      defs: [],
      includes: [],
      root: p".",
      sources: [
        p"build.c",
        p"deps.c",
        p"env.c",
        p"graph.c",
        p"htab.c",
        p"log.c",
        p"os-posix.c",
        p"parse.c",
        p"samu.c",
        p"scan.c",
        p"tool.c",
        p"tree.c",
        p"util.c",
      ],
      out_dir: p"obj",
      out: p"obj/samu",
      libs: [],
      ldflags: [],
      deps: [],
    },
  )

  make.run_tasks(samu.tasks, make.jobs()?)?

  # Install binary and ninja symlink.
  fs.install(samu.output, fp"{dest}/usr/bin/samu", 0o755, parents: true, overwrite: true)?
  fs.symlink(p"samu", fp"{dest}/usr/bin/ninja")?
}
