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

## Runtime link inputs matching the tarball DT_NEEDED: libfreetype,
## libharfbuzz, librust_fontconfig, libEGL (mesa), libwayland-client,
## libxkbcommon, plus musl.
export const deps = ["musl", "mesa", "wayland-libs-client", "libxkbcommon", "freetype", "harfbuzz", "rust-fontconfig"]

## Font files and XKB data are runtime lookups, not link inputs.
export const runtime_only_deps = ["font-ttf-hack", "xkeyboard-config"]

## Package recipe export.
export const mkdeps_host = ["tic"]

## Ghostty Custom Wayland-only musl tarballs from joshuarli/ghostty at the
## pinned commit c4f036c72; arch-pinned with recorded SHA-256, no SKIP. Built with
## `zig build -Dapp-runtime=wayland -Dfont-backend=rust_fontconfig_freetype`
## (no GTK/Adwaita/X11); Linux binaries are mostly-static musl with dynamic
## libfreetype, libharfbuzz, librust_fontconfig, libEGL, libwayland-client and
## libxkbcommon only. SHA256SUMS at the release: x86_64 a269c413..., aarch64 8d7b942c....
export const upstream_sources = [
  {
    source: p"https://github.com/joshuarli/ghostty/releases/download/release-c4f036c721c3e48f02568222b5f3dfbc86acd817/ghostty-custom-ARCH-linux-musl.tar.gz => ghostty",
    kind: "file",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "x86_64",
        sha256: "a269c4133e381bf252c5c2026040dc964549ef9c9062c1c39c337de872efd93b",
      },
      {
        arch: "aarch64",
        sha256: "8d7b942c188b86c4cbfafe0a45c18f8633d324f61283694cd0b762b96a6e0a8a",
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
