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
export const rel = "1"

## Runtime link inputs matching the tarball DT_NEEDED: libEGL (mesa),
## libwayland-client, libxkbcommon, plus musl. Fontconfig is statically
## linked; fonts and XKB data are runtime lookups.
export const deps = ["musl", "mesa", "wayland-libs-client", "libxkbcommon"]

## Fonts and XKB data are runtime lookups, not link inputs.
export const runtime_only_deps = ["font-ttf-hack", "xkeyboard-config"]

## Package recipe export.
export const mkdeps_host = ["tic"]

## Ghostty Custom Wayland-only musl tarballs from joshuarli/ghostty at the
## pinned commit; arch-pinned with recorded SHA-256, no SKIP. Built with
## `zig build -Dapp-runtime=wayland` (no GTK/Adwaita/X11); Linux binaries are
## mostly-static musl with dynamic libEGL, libwayland-client, libxkbcommon only.
## SHA256SUMS at the release: x86_64 7de995d7..., aarch64 56409052....
export const upstream_sources = [
  {
    source: p"https://github.com/joshuarli/ghostty/releases/download/release-354a4e32dc4959ec10709adbdeac114594a05097/ghostty-custom-ARCH-linux-musl.tar.gz => ghostty",
    kind: "file",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "bb7811e445cc2e6079c657bc8827d479691275117b88b242a69cfd8c449913e7",
      },
      {
        arch: "aarch64",
        sha256: "56409052a57d1f30df71d29a03a350c296aeecb6899493b5b9285488ea228848",
      },
    ],
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
