##! XSH module `PKGBUILD` package and build operations.
use pm.types
use pm.util as pm_util

## Package recipe export.
export const name = "ghostty-custom"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Upstream Ghostty version; the custom Wayland-only musl build is pinned
## by commit below. The binary reports `Ghostty 1.4.1-dev+000000`.
export const ver = "1.4.1"

## Package recipe export.
export const rel = "5"

## Runtime link inputs of the local shared-font binary.
export const deps = ["musl", "mesa", "wayland-libs-client", "libxkbcommon", "freetype", "harfbuzz", "fontconfig"]

## Fonts and XKB data are runtime lookups, not link inputs.
export const runtime_only_deps = ["font-ttf-hack", "font-ttf-dejavu-sans", "xkeyboard-config"]

## Package recipe export.
export const mkdeps_host = ["tic"]

## Local qualification archive, with its checksum supplied by the caller.
export const upstream_sources = [
  {
    source: p"files/ghostty-local.tar.gz => ghostty",
    kind: "file",
    architectures: ["x86_64"],
    checksums: [{arch: "x86_64", sha256: "LOCAL_ARCHIVE_SHA256"}],
  },
  {
    source: p"files/xterm-ghostty.info => terminfo",
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
export const filetree = [
  {path: p"usr/bin/ghostty-custom", kind: "binary"},
  {path: p"usr/share/terminfo", kind: "tree"},
]

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let tic = process.which("tic")?
  let tars = fs.walk(p".", gitignore: false)? |> where .kind == "file" and .ext == "gz"
  guard tars.len() == 1 else {
    return Err(types.PmError.PackageContract(f"ghostty-custom: expected one tarball, found {tars.len()}"))
  }

  tempdir unpacked {
    archive.extract(tars[0].path, unpacked, .Tar, compression: .Gzip, collision: .Replace)
    let bins = fs.walk(unpacked, gitignore: false)? |> where .kind == "file" and .name == "ghostty"
    guard bins.len() == 1 else {
      return Err(types.PmError.PackageContract(f"ghostty-custom: expected one ghostty binary, found {bins.len()}"))
    }

    fs.install(bins[0].path, fp"{dest}/usr/bin/ghostty-custom", 0o755, parents: true, overwrite: true)
  }

  let infos = fs.walk(p".", gitignore: false)? |> where .kind == "file" and .name == "xterm-ghostty.info"
  guard infos.len() == 1 else {
    return Err(types.PmError.PackageContract(f"ghostty-custom: expected one terminfo source, found {infos.len()}"))
  }

  let database = fp"{dest}/usr/share/terminfo"
  run $tic -x -o $database infos[0].path
}
