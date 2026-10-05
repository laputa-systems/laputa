##! Package recipe metadata and build operations.
## Package recipe export.
export const name = "xkeyboard-config"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "2.48"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export let deps = []

## Package recipe export.
export let mkdeps_host = []

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://xorg.freedesktop.org/archive/individual/data/xkeyboard-config/xkeyboard-config-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b77041324f0109f77161ee43743fe04baa485866af8460d31e476ad3f7648fd5",
      },
    ],
  },
  # The base and evdev rules files come from upstream's Python rules
  # generator. Regenerate them on the host (Python 3.11 or newer) from the
  # unpacked source tree, without the compatibility rules, whose layout
  # aliases need generated symbols files this package does not ship:
  #   python3 -m rules.generator rules --ruleset base --version v2 \
  #     --output files/generated/base rules/rules.in
  # and the same with `--ruleset evdev` into files/generated/evdev.
  {
    source: p"files/generated/base => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "d9cfcc5a70cd3e47e9343a98d2fd991f02a235e81e76adf2c3fac8fec730fcd7",
      },
    ],
  },
  {
    source: p"files/generated/evdev => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "ab627a66a257977d03b875475ac4dbd245bc83b5dc71a2d8b3dc1bfe30ed6ba2",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr",
    kind: "tree",
  },
  {
    path: p"usr/share/X11/xkb",
    kind: "symlink",
  },
  {
    path: p"usr/share/pkgconfig/xkeyboard-config.pc",
    kind: "symlink",
  },
  {
    path: p"usr/share/xkeyboard-config-2/symbols/caps",
    kind: "symlink",
  },
  {
    path: p"usr/share/xkeyboard-config-2/symbols/esperanto",
    kind: "symlink",
  },
  {
    path: p"usr/share/xkeyboard-config-2/symbols/grp",
    kind: "symlink",
  },
  {
    path: p"usr/share/xkeyboard-config-2/symbols/japan",
    kind: "symlink",
  },
  {
    path: p"usr/share/xkeyboard-config-2/symbols/korean",
    kind: "symlink",
  },
  {
    path: p"usr/share/xkeyboard-config-2/symbols/lv2",
    kind: "symlink",
  },
  {
    path: p"usr/share/xkeyboard-config-2/symbols/lv3",
    kind: "symlink",
  },
  {
    path: p"usr/share/xkeyboard-config-2/symbols/lv5",
    kind: "symlink",
  },
]

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  let base = fp"{dest}/usr/share/xkeyboard-config-2"
  base.mkdir()

  for dir in [p"compat", p"geometry", p"keycodes", p"symbols", p"types"] {
    let _ = fs.copy_tree(dir, fp"{base}/{dir.name}", parents: true, overwrite: true)?
  }

  # Upstream installs neither its symbols build file nor the custom types stub.
  fp"{base}/symbols/meson.build".remove(missing_ok: false)
  fp"{base}/types/custom".remove(missing_ok: false)
  fp"{base}/rules".mkdir()

  for ruleset in ["base", "evdev"] {
    fs.install(fp"generated/{ruleset}", fp"{base}/rules/{ruleset}", 0o644, parents: true, overwrite: true)
    fs.install(p"rules/base.xml", fp"{base}/rules/{ruleset}.xml", 0o644, parents: true, overwrite: true)
    fs.install(p"rules/base.extras.xml", fp"{base}/rules/{ruleset}.extras.xml", 0o644, parents: true, overwrite: true)
    fp"{base}/rules/{ruleset}.lst".write("")
  }

  fs.install(p"rules/xkb.dtd", fp"{base}/rules/xkb.dtd", 0o644, parents: true, overwrite: true)
  fp"{dest}/usr/share/X11".mkdir()
  fs.symlink(../xkeyboard-config-2, fp"{dest}/usr/share/X11/xkb")
  fp"{dest}/usr/share/pkgconfig".mkdir()

  fp"{dest}/usr/share/pkgconfig/xkeyboard-config-2.pc".write(
    f"""prefix=/usr
datadir=\${{prefix}}/share
xkb_root=\${{datadir}}/xkeyboard-config-2
xkb_base=\${{datadir}}/X11/xkb

Name: XKeyboardConfig
Description: X Keyboard configuration data
Version: {ver}
""",
  )

  fs.symlink(p"xkeyboard-config-2.pc", fp"{dest}/usr/share/pkgconfig/xkeyboard-config.pc")
}

