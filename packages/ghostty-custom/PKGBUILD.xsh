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
export const rel = "6"

## Runtime link inputs matching the tarball DT_NEEDED: libfreetype,
## libharfbuzz, librust_fontconfig, libEGL (mesa), libwayland-client,
## libxkbcommon, plus musl.
export const deps = ["musl", "mesa", "wayland-libs-client", "libxkbcommon", "freetype", "harfbuzz", "rust-fontconfig"]

## Font files and XKB data are runtime lookups, not link inputs.
export const runtime_only_deps = ["font-ttf-hack", "xkeyboard-config"]

## Package recipe export.
export const mkdeps_host = ["tic"]

## Ghostty Custom Wayland-only musl tarballs from joshuarli/ghostty at the
## pinned commit 9438d6d83c; arch-pinned with recorded SHA-256, no SKIP. Built with
## `zig build -Dapp-runtime=wayland -Dfont-backend=rust_fontconfig_freetype`
## (no GTK/Adwaita/X11); Linux binaries are mostly-static musl with dynamic
## libfreetype, libharfbuzz, librust_fontconfig, libEGL, libwayland-client and
## libxkbcommon only. SHA256SUMS at the release: x86_64 abf36898..., aarch64 11e58bae....
export const upstream_sources = [
  {
    source: p"https://github.com/joshuarli/ghostty/releases/download/release-9438d6d83cfbb4bf408f11d38dfba0f0db94d65d/ghostty-custom-ARCH-linux-musl.tar.xz => ghostty",
    kind: "file",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "abf3689815025ada335ca2770e81755ab37557b48f43e3aef6597803f39702b8",
      },
      {
        arch: "aarch64",
        sha256: "11e58bae6eac864742c2041b373a4520fcab691681ca0241439da0d006966026",
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
  let tars = fs.walk(p".", gitignore: false)? |> where .kind == "file" and .ext == "xz"
  guard tars.len() == 1 else {
    return Err(types.PmError.PackageContract(f"ghostty-custom: expected one tarball, found {tars.len()}"))
  }

  tempdir unpacked {
    archive.extract(tars[0].path, unpacked, .Tar, compression: .Xz, collision: .Replace)
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
