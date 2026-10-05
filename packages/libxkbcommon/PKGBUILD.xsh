##! XSH module `PKGBUILD` package and build operations.
use pm.env as pm_env

## Exported declaration `name`.
export const name = "libxkbcommon"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1.13.2"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl", "xkeyboard-config"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "muon", "samurai", "pkgconf", "xkeyboard-config"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://github.com/xkbcommon/libxkbcommon/archive/xkbcommon-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "acc4d5f7c3cbba5f9f8d08d8bdbeede84ecede46792f47929aa9321873385528",
      },
    ],
  },
  {
    source: p"files/parser.c => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "f77e4c07f6b74579a3b703544f36be7a853ee3ae95a90f32b944f11b9b455650",
      },
    ],
  },
  {
    source: p"files/parser.h => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "3d7668420fae724667a73b80134cc89271934e2fa46478a9c0daaac97297ea3a",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/include/xkbcommon/xkbcommon-compat.h",
    kind: "file",
  },
  {
    path: p"usr/include/xkbcommon/xkbcommon-compose.h",
    kind: "file",
  },
  {
    path: p"usr/include/xkbcommon/xkbcommon-keysyms.h",
    kind: "file",
  },
  {
    path: p"usr/include/xkbcommon/xkbcommon-names.h",
    kind: "file",
  },
  {
    path: p"usr/include/xkbcommon/xkbcommon.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libxkbcommon.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libxkbcommon.so.0",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libxkbcommon.so.0.13.2",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/xkbcommon.pc",
    kind: "file",
  },
]

# files/parser.c and files/parser.h replace upstream's Bison step. Regenerate
# them on the host with GNU Bison 3.8.2 from the directory holding the
# unpacked source tree, using the flags of upstream's yacc_gen:
#   bison --defines=parser.h -o parser.c -p _xkbcommon_ \
#     libxkbcommon-xkbcommon-VERSION/src/xkbcomp/parser.y
proc patch_vendored_parser() {
  fs.install(p"generated/parser.c", p"src/xkbcomp/parser.c", 0o644, parents: true, overwrite: true)
  fs.install(p"generated/parser.h", p"src/xkbcomp/parser.h", 0o644, parents: true, overwrite: true)
  let meson = p"meson.build"
  var text = meson.read_text()?

  text = text.replace(
    """# libxkbcommon.
bison = find_program('bison', 'win_bison', required: true, version: '>= 3.6')
yacc = bison
yacc_gen = generator(
    bison,
    output: ['@BASENAME@.c', '@BASENAME@.h'],
    arguments: ['--defines=@OUTPUT1@', '-o', '@OUTPUT0@', '-p', '_xkbcommon_', '@INPUT@'],
)
""",
    """# libxkbcommon.
yacc = 'vendored parser'
""",
  )

  text = text.replace(
    "    yacc_gen.process('src/xkbcomp/parser.y'),",
    """    'src/xkbcomp/parser.c',
    'src/xkbcomp/parser.h',""",
  )

  text = text.replace("'yacc': yacc.full_path() + ' ' + yacc.version(),", "'yacc': yacc,")
  meson.write(text)
}

# pkgconf reports xkeyboard-config.pc's path variables under the build root's
# sysroot, so the legacy root read from xkb_base would name the build root.
# Without it, meson falls back to prefix/datadir/X11/xkb, the installed path.
proc patch_legacy_root() {
  let meson = p"meson.build"
  let text = meson.read_text()?
  let lookup = """XKB_LEGACY_ROOT = ''
foreach v: ['-2', '']
    xkeyboard_config_dep = dependency(f'xkeyboard-config@v@', required: false)
    if xkeyboard_config_dep.found()
        XKB_LEGACY_ROOT = xkeyboard_config_dep.get_variable(
            pkgconfig: 'xkb_base',
            default_value: ''
        )
        break
    endif
endforeach
"""

  if lookup not in text {
    return Err(error.failure("meson.build no longer reads the legacy XKB root from pkg-config"))?
  }

  meson.write(text.replace(lookup, "XKB_LEGACY_ROOT = ''\n"))
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let muon = process.which("muon")?
  let pc = pm_env.pkg_config_context()?
  patch_vendored_parser()
  patch_legacy_root()

  env ({
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    # The extension paths default to xkeyboard-config.pc's xkb_root, which pkgconf
    # reports under the build root's sysroot; name the installed paths instead.
    run $muon "setup" pm_env.meson_prefix_arg() pm_env.meson_libdir_arg() pm_env.meson_sysconfdir_arg() "-Ddefault_library=shared" "-Dxkb-config-root=/usr/share/X11/xkb" "-Dxkb-config-versioned-extensions-path=/usr/share/xkeyboard-config-2.d" "-Dxkb-config-unversioned-extensions-path=/usr/share/xkeyboard-config.d" "-Denable-docs=false" "-Denable-tools=false" "-Denable-x11=false" "-Denable-wayland=false" "-Denable-xkbregistry=false" "-Denable-bash-completion=false" "build"
    run $muon "-C" "build" samu "-j1" "libxkbcommon.so.0.13.2"

    env ({
      DESTDIR: dest,
    }) {
      run $muon "-C" "build" install
    }
  }

  fp"{dest}/usr/share/bash-completion".remove(missing_ok: true)
}
