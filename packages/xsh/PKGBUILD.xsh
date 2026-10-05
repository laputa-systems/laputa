##! Package recipe metadata and build operations.
use pm.util as pm_util

## Package recipe export.
export const name = "xsh"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "0.0.0"

## Package recipe export.
export const rel = "16"

## Package recipe export.
export let deps = []

## Package recipe export.
export let mkdeps_host = []

## Package recipe export.
## The in-world XSH is the local seed `make seed` builds from XSH_ROOT, not a
## published release and not compiled in-world. The target's seed directory is
## a repository input, so its manifest and products are hashed into this
## package's build key for that target only; the build verifies each product
## against the manifest.
export const upstream_sources = [
  {
    source: p"repository/.out/seed/ARCH => seed",
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
export const nostrip = true

## Package recipe export.
## Core applets live under one tree so a new XSH applet needs no recipe edit
## for its script; its `usr/bin` symlink must still be declared here.
export const filetree = [
  {path: p"usr/bin/basename", kind: "symlink"},
  {path: p"usr/bin/cat", kind: "symlink"},
  {path: p"usr/bin/chgrp", kind: "symlink"},
  {path: p"usr/bin/chmod", kind: "symlink"},
  {path: p"usr/bin/chown", kind: "symlink"},
  {path: p"usr/bin/cp", kind: "symlink"},
  {path: p"usr/bin/cut", kind: "symlink"},
  {path: p"usr/bin/date", kind: "symlink"},
  {path: p"usr/bin/df", kind: "symlink"},
  {path: p"usr/bin/dirname", kind: "symlink"},
  {path: p"usr/bin/du", kind: "symlink"},
  {path: p"usr/bin/env", kind: "symlink"},
  {path: p"usr/bin/fd", kind: "symlink"},
  {path: p"usr/bin/fold", kind: "symlink"},
  {path: p"usr/bin/getty", kind: "symlink"},
  {path: p"usr/bin/head", kind: "symlink"},
  {path: p"usr/bin/host", kind: "symlink"},
  {path: p"usr/bin/hostname", kind: "symlink"},
  {path: p"usr/bin/ifdown", kind: "symlink"},
  {path: p"usr/bin/ifup", kind: "symlink"},
  {path: p"usr/bin/ip", kind: "symlink"},
  {path: p"usr/bin/link", kind: "symlink"},
  {path: p"usr/bin/ln", kind: "symlink"},
  {path: p"usr/bin/ls", kind: "symlink"},
  {path: p"usr/bin/mdev", kind: "symlink"},
  {path: p"usr/bin/mkdir", kind: "symlink"},
  {path: p"usr/bin/mv", kind: "symlink"},
  {path: p"usr/bin/nproc", kind: "symlink"},
  {path: p"usr/bin/passwd", kind: "symlink"},
  {path: p"usr/bin/paste", kind: "symlink"},
  {path: p"usr/bin/printenv", kind: "symlink"},
  {path: p"usr/bin/printf", kind: "symlink"},
  {path: p"usr/bin/pstree", kind: "symlink"},
  {path: p"usr/bin/pwd", kind: "symlink"},
  {path: p"usr/bin/readlink", kind: "symlink"},
  {path: p"usr/bin/realpath", kind: "symlink"},
  {path: p"usr/bin/rev", kind: "symlink"},
  {path: p"usr/bin/rg", kind: "symlink"},
  {path: p"usr/bin/rm", kind: "symlink"},
  {path: p"usr/bin/rmdir", kind: "symlink"},
  {path: p"usr/bin/seq", kind: "symlink"},
  {path: p"usr/bin/sh", kind: "symlink"},
  {path: p"usr/bin/shuf", kind: "symlink"},
  {path: p"usr/bin/sort", kind: "symlink"},
  {path: p"usr/bin/split", kind: "symlink"},
  {path: p"usr/bin/stat", kind: "symlink"},
  {path: p"usr/bin/strings", kind: "symlink"},
  {path: p"usr/bin/system-report", kind: "symlink"},
  {path: p"usr/bin/tail", kind: "symlink"},
  {path: p"usr/bin/tar", kind: "symlink"},
  {path: p"usr/bin/tee", kind: "symlink"},
  {path: p"usr/bin/touch", kind: "symlink"},
  {path: p"usr/bin/tr", kind: "symlink"},
  {path: p"usr/bin/tree", kind: "symlink"},
  {path: p"usr/bin/uname", kind: "symlink"},
  {path: p"usr/bin/uniq", kind: "symlink"},
  {path: p"usr/bin/wc", kind: "symlink"},
  {path: p"usr/bin/which", kind: "symlink"},
  {path: p"usr/bin/xsh", kind: "binary"},
  {path: p"usr/bin/xshi", kind: "binary"},
  {path: p"usr/bin/xsht", kind: "binary"},
  {path: p"usr/lib/xsh/core", kind: "tree"},
]

# The seed products the build installs, each checked against the seed manifest.
const seed_products = ["xsh", "xshi", "xsht", "core.tar.xz"]

proc verified_seed(arch: Str) -> Result[Path] {
  let seed = p"seed"
  let manifest_path = fp"{seed}/manifest.json"

  if ! manifest_path.exists() {
    fail f"the {arch} XSH seed has no manifest; run `make seed ARCH={arch}`"
  }

  let manifest = json.read(manifest_path)?.require(Record)?
  let files = manifest.get("files")?.require(Record)?

  for product in seed_products {
    let expected: Str = files.get(product)?.require()?
    let actual = hash.sha256(fp"{seed}/{product}")?.hex()

    if actual != expected {
      fail f"seed {product} has sha256 {actual}, its manifest records {expected}"
    }
  }

  seed
}

## Package recipe export.
## Immutable root preflight owns collision detection, so this payload build
## never deletes files from a live root.
export proc build(dest: Path) [fs, env, error] {
  let seed = verified_seed(pm_util.target_arch()?)?

  for product in ["xsh", "xshi", "xsht"] {
    fs.install(fp"{seed}/{product}", fp"{dest}/usr/bin/{product}", 0o755, parents: true, overwrite: true)
  }

  let shell = fp"{dest}/usr/bin/sh"
  shell.remove()
  shell.symlink(to: p"xshi")

  let core = fp"{dest}/usr/lib/xsh/core"
  core.parent.mkdir()
  archive.tar_extract(fp"{seed}/core.tar.xz", core.parent, 0, "xz", true)

  for entry in fs.children(core)? |> where .kind == "file" and .name != "su" {
    fp"{dest}/usr/bin/{entry.name}".symlink(to: fp"../lib/xsh/core/{entry.name}")
  }
}
