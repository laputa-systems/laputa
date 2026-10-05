##! XSH module `PKGBUILD` package and build operations.
use pm.env as pm_env
use pm.make

## Exported declaration `name`.
export const name = "fontconfig"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "2.18.3"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl", "freetype", "expat"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "muon", "samurai", "pkgconf", "freetype", "expat"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/VERSION/fontconfig-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "4f7b554a38cdf78c033f666c8871f3749e14a094f65a07f630c91ed0b43d35e3",
      },
    ],
  },
  {
    source: p"files/generated/fccase.h => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "379b8c9b6b9a46d0211be25298542a49691bdd0be0508e1b7d143b0857fd23a0",
      },
    ],
  },
  {
    source: p"files/generated/fclang.h => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "efcc1203e94b27fbf9296ad10a5c0e93f561a417767c4dd268f8c685fa4896ec",
      },
    ],
  },
  {
    source: p"files/generated/35-lang-normalize.conf => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "71508125319069a75081953cd4d00c41fc7c9c77c2c9881a6e69b23f7fd97d34",
      },
    ],
  },
  {
    source: p"files/generated/fcconst.h => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "1cfb6ba5313d2683a747156f5b22fe74280fd37107e24ed0c0cc1661855629dd",
      },
    ],
  },
  {
    source: p"files/generated/fcgenericfamily.h => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "00364cb2458412c4ae6596180d42e5a8309f1b3aeaf353b4800ca074069a0c0c",
      },
    ],
  },
  {
    source: p"files/generated/fcobjshash.h => generated",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b351f54df41f4ae49b7bce469befca39af3c8308a004e7a8c12ed2e914aa98c4",
      },
    ],
  },
]

const conf_links = [
  "10-scale-bitmap-fonts.conf",
  "10-yes-antialias.conf",
  "11-lcdfilter-default.conf",
  "20-unhint-small-vera.conf",
  "30-metric-aliases.conf",
  "40-nonlatin.conf",
  "45-generic.conf",
  "45-latin.conf",
  "48-guessfamily.conf",
  "48-spacing.conf",
  "49-sansserif.conf",
  "50-user.conf",
  "51-local.conf",
  "60-generic.conf",
  "60-latin.conf",
  "65-fonts-persian.conf",
  "65-nonlatin.conf",
  "69-unifont.conf",
  "80-delicious.conf",
  "90-synthetic.conf",
  "10-hinting-slight.conf",
  "10-sub-pixel-none.conf",
  "70-no-bitmaps-except-emoji.conf",
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"etc/fonts/conf.d/10-hinting-slight.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/10-scale-bitmap-fonts.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/10-sub-pixel-none.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/10-yes-antialias.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/11-lcdfilter-default.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/20-unhint-small-vera.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/30-metric-aliases.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/40-nonlatin.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/45-generic.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/45-latin.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/48-guessfamily.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/48-spacing.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/49-sansserif.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/50-user.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/51-local.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/60-generic.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/60-latin.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/65-fonts-persian.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/65-nonlatin.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/69-unifont.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/70-no-bitmaps-except-emoji.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/80-delicious.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/90-synthetic.conf",
    kind: "symlink",
  },
  {
    path: p"etc/fonts/conf.d/README",
    kind: "file",
  },
  {
    path: p"etc/fonts/fonts.conf",
    kind: "file",
  },
  {
    path: p"usr/bin/fc-cache",
    kind: "binary",
  },
  {
    path: p"usr/bin/fc-match",
    kind: "binary",
  },
  {
    path: p"usr/include/fontconfig/fcfreetype.h",
    kind: "file",
  },
  {
    path: p"usr/include/fontconfig/fcprivate.h",
    kind: "file",
  },
  {
    path: p"usr/include/fontconfig/fontconfig.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libfontconfig.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libfontconfig.so.1",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libfontconfig.so.1.17.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/fontconfig.pc",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/05-reset-dirs-sample.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/09-autohint-if-no-hinting.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-autohint.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-hinting-full.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-hinting-medium.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-hinting-none.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-hinting-slight.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-no-antialias.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-scale-bitmap-fonts.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-sub-pixel-bgr.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-sub-pixel-none.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-sub-pixel-vbgr.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-sub-pixel-vrgb.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-unhinted.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/10-yes-antialias.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/11-lcdfilter-default.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/11-lcdfilter-legacy.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/11-lcdfilter-light.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/11-lcdfilter-none.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/20-unhint-small-vera.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/25-unhint-nonlatin.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/30-metric-aliases.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/35-lang-normalize.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/40-nonlatin.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/45-generic.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/45-latin.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/48-guessfamily.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/48-spacing.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/49-sansserif.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/50-user.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/51-local.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/60-generic.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/60-latin.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/65-fonts-persian.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/65-khmer.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/65-nonlatin.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/69-unifont.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/70-no-bitmaps-and-emoji.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/70-no-bitmaps-except-emoji.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/70-no-bitmaps.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/70-yes-bitmaps.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/80-delicious.conf",
    kind: "file",
  },
  {
    path: p"usr/share/fontconfig/conf.avail/90-synthetic.conf",
    kind: "file",
  },
  {
    path: p"usr/share/xml/fontconfig/fonts.dtd",
    kind: "file",
  },
]

proc replace_required(file: Path, old: Str, new: Str) {
  let text = file.read_text()?

  if old not in text {
    return Err(error.failure(f"{file} no longer holds the block the recipe replaces"))?
  }

  file.write(text.replace(old, with: new))
}

# Upstream's makealias.py emits hidden internal aliases for the public
# symbols, an optimization only; empty headers build the same library with
# PLT calls between its own functions.
proc write_empty_alias_headers() {
  for header in [p"fcalias.h", p"fcaliastail.h", p"fcftalias.h", p"fcftaliastail.h"] {
    header.write("")
  }
}

# files/generated/ replaces upstream's Python and gperf build steps. Each
# file is what the corresponding custom target in upstream's meson files
# produces; regenerate them on the host from the unpacked source tree with
# Python 3 and GNU gperf 3.3, where ORTHS is the orth_files list of
# fc-lang/meson.build, in order:
#   python3 fc-case/fc-case.py fc-case/CaseFolding.txt \
#     --template fc-case/fccase.tmpl.h --output fccase.h
#   python3 fc-lang/fc-lang.py ORTHS --template fc-lang/fclang.tmpl.h \
#     --output fclang.h --directory fc-lang
#   python3 conf.d/write-35-lang-normalize-conf.py LANGS 35-lang-normalize.conf
#     (LANGS: ORTHS without `.orth` and without names holding `_`, joined by `,`)
#   python3 fc-const/fc-const.py fc-const/fcconst.list src/fcobjs.h --output fcconst.h
#   python3 fc-genericfamily/fc-genericfamily.py -d fc-genericfamily -o fcgenericfamily.gperf
#   gperf --pic -m 100 fcgenericfamily.gperf --output-file fcgenericfamily.h
# fcobjshash.h comes from src/fcobjshash.gperf.h preprocessed with -I. and
# -Ifc-lang plus a fontconfig/fontconfig.h configured from its .h.in (cache
# version 12, minimum compatible 9, snapshot 0, next 0):
#   cc -E -P ... src/fcobjshash.gperf.h -o fcobjshash.gperf.h
#   python3 src/cutout.py fcobjshash.gperf.h fcobjshash.gperf
#   gperf --pic -m 100 fcobjshash.gperf --output-file fcobjshash.h
# Run gperf in the directory holding its input so its output names no host path.
# fcconst.h, fcgenericfamily.h, and fcobjshash.h go beside the sources in src/
# that include them, where upstream relies on generated-header include paths.
proc patch_generated_build_inputs() {
  fs.install(p"generated/fccase.h", p"fc-case/fccase.h", 0o644, overwrite: true)
  fs.install(p"generated/fclang.h", p"fc-lang/fclang.h", 0o644, overwrite: true)
  fs.install(p"generated/fcconst.h", p"src/fcconst.h", 0o644, overwrite: true)
  fs.install(p"generated/fcgenericfamily.h", p"src/fcgenericfamily.h", 0o644, overwrite: true)
  fs.install(p"generated/fcobjshash.h", p"src/fcobjshash.h", 0o644, overwrite: true)
  fs.install(p"generated/35-lang-normalize.conf", p"conf.d/35-lang-normalize.conf", 0o644, overwrite: true)
  write_empty_alias_headers()
  let meson = p"meson.build"

  replace_required(meson, """    'rust_std=2021',
""", "")

  replace_required(
    meson,
    "math_dep = cc.find_library('m', required: false)",
    "math_dep = declare_dependency(link_args: ['-lm'])",
  )

  replace_required(
    meson,
    """foreach check : check_sizeofs
  type = check[0]
  opts = check.length() > 1 ? check[1] : {}

  conf_name = opts.get('conf-name', 'SIZEOF_@0@'.format(type.to_upper()))

  conf.set(conf_name, cc.sizeof(type))
endforeach

foreach check : check_alignofs
  type = check[0]
  opts = check.length() > 1 ? check[1] : {}

  conf_name = opts.get('conf-name', 'ALIGNOF_@0@'.format(type.to_upper()))

  conf.set(conf_name, cc.alignment(type))
endforeach
""",
    """foreach check : check_sizeofs
  type = check[0]
  opts = check.length() > 1 ? check[1] : {}
  conf_name = opts.get('conf-name', 'SIZEOF_@0@'.format(type.to_upper()))
  conf.set(conf_name, type == 'void *' ? 8 : cc.sizeof(type))
endforeach

foreach check : check_alignofs
  type = check[0]
  opts = check.length() > 1 ? check[1] : {}
  conf_name = opts.get('conf-name', 'ALIGNOF_@0@'.format(type.to_upper()))
  conf.set(conf_name, (type == 'void *' or type == 'double') ? 8 : cc.alignment(type))
endforeach
""",
  )

  replace_required(meson, "python3 = import('python').find_installation()\n", "")

  # gperf 3.1 and later type lengths as size_t, as the vendored output does.
  replace_required(
    meson,
    """gperf = find_program('gperf', required: false)
gperf_len_type = ''

if gperf.found() and get_option('wrap_mode') != 'forcefallback'
  gperf_test_format = '''
  #include <string.h>
  const char * in_word_set(const char *, @0@);
  @1@
  '''
  gperf_snippet = run_command(gperf, '-L', 'ANSI-C', files('meson-cc-tests/gperf.txt'),
                              check: true).stdout()

  foreach type : ['size_t', 'unsigned']
    if cc.compiles(gperf_test_format.format(type, gperf_snippet))
      gperf_len_type = type
      break
    endif
  endforeach

  if gperf_len_type == ''
    error('unable to determine gperf len type')
  endif
else
  # Fallback to subproject
  gperf = find_program('gperf')
  # assume if we are compiling from the wrap, the size is just size_t
  gperf_len_type = 'size_t'
endif
""",
    """gperf_len_type = 'size_t'
""",
  )

  replace_required(
    meson,
    """alias_headers = custom_target('alias_headers',
                              output: ['fcalias.h', 'fcaliastail.h'],
                              input: alias_input_headers,
                              command: [python3, makealias, join_paths(meson.current_source_dir(), 'src'), '@OUTPUT@', '@INPUT@'],
                             )

ft_alias_headers = custom_target('ft_alias_headers',
                                 output: ['fcftalias.h', 'fcftaliastail.h'],
                                 input: ['fontconfig/fcfreetype.h'],
                                 command: [python3, makealias, join_paths(meson.current_source_dir(), 'src'), '@OUTPUT@', '@INPUT@']
                                )
""",
    """alias_headers = files('fcalias.h', 'fcaliastail.h')
ft_alias_headers = files('fcftalias.h', 'fcftaliastail.h')
""",
  )

  replace_required(
    p"src/meson.build",
    """fcobjshash_h = cc.preprocess('fcobjshash.gperf.h', include_directories: incbase)
fcobjshash_gperf = custom_target(
  input: fcobjshash_h,
  output: 'fcobjshash.gperf',
  command: ['cutout.py', '@INPUT@', '@OUTPUT@'],
  build_by_default: true,
)

fcobjshash_h = custom_target(
  'fcobjshash.h',
  input: fcobjshash_gperf,
  output: 'fcobjshash.h',
  command: [gperf, '--pic', '-m', '100', '@INPUT@', '--output-file', '@OUTPUT@'],
)
""",
    """fcobjshash_h = files('fcobjshash.h')
""",
  )

  replace_required(
    p"fc-case/meson.build",
    """fccase_h = custom_target('fccase.h',
  output: 'fccase.h',
  input: ['CaseFolding.txt', 'fccase.tmpl.h'],
  command: [find_program('fc-case.py'), '@INPUT0@', '--template', '@INPUT1@', '--output', '@OUTPUT@'])
""",
    """fccase_h = files('fccase.h')
""",
  )

  replace_required(
    p"fc-lang/meson.build",
    """fclang_h = custom_target(
  'fclang.h',
  output: ['fclang.h'],
  input: orth_files,
  command: [
    find_program('fc-lang.py'),
    orth_files,
    '--template',
    files('fclang.tmpl.h')[0],
    '--output',
    '@OUTPUT@',
    '--directory',
    meson.current_source_dir(),
  ],
  build_by_default: true,
)
""",
    """fclang_h = files('fclang.h')
""",
  )

  # The fc-const target also writes a test-only source; tests are disabled.
  replace_required(
    p"fc-const/meson.build",
    """fcconst_h = custom_target('fcconst.h',
  output: 'fcconst.h',
  input: ['fcconst.list', fcobjs_h],
  command: [find_program('fc-const.py'), '@INPUT0@', '@INPUT1@', '--output', '@OUTPUT@'])
test_const_name_c = custom_target('test_const_name.c',
  output: 'test_const_name.c',
  input: ['fcconst.list', fcobjs_h],
  command: [find_program('fc-const.py'), '-t', '@INPUT0@', '@INPUT1@', '--output', '@OUTPUT@'])
""",
    """fcconst_h = files('../src/fcconst.h')
""",
  )

  let genericfamily_meson = p"fc-genericfamily/meson.build"
  let genericfamily_text = genericfamily_meson.read_text()?

  if "command: [gperf, '--pic', '-m', '100', '@INPUT@', '--output-file', '@OUTPUT@']," not in genericfamily_text {
    return Err(error.failure(f"{genericfamily_meson} no longer runs gperf on the generated families"))?
  }

  genericfamily_meson.write("fcgenericfamily_h = files('../src/fcgenericfamily.h')\n")
  let conf_meson = p"conf.d/meson.build"

  replace_required(
    conf_meson,
    """custom_target('35-lang-normalize.conf',
  output: '35-lang-normalize.conf',
  command: [find_program('write-35-lang-normalize-conf.py'), ','.join(orths), '@OUTPUT@'],
  install_dir: fc_templatedir,
  install: true,
  install_tag: 'runtime')
""",
    """install_data('35-lang-normalize.conf',
             install_dir: fc_templatedir,
             install_tag: 'runtime')
""",
  )

  # The recipe links conf_links itself after install.
  replace_required(
    conf_meson,
    """meson.add_install_script('link_confs.py', fc_templatedir,
                         fc_configdir,
                         conf_links,
                         install_tag: 'runtime')
""",
    "",
  )
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let muon = process.which("muon")?
  let jobs_flag = f"-j{make.jobs()?}"
  let pc = pm_env.pkg_config_context()?
  patch_generated_build_inputs()

  env ({
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    run $muon "setup" pm_env.meson_prefix_arg() pm_env.meson_libdir_arg() pm_env.meson_sysconfdir_arg() pm_env.meson_localstatedir_arg() "-Ddefault_library=shared" "-Ddoc=disabled" "-Dtests=disabled" "-Dnls=disabled" "-Diconv=disabled" "-Dxml-backend=expat" "-Dfontations=disabled" "-Dcache-build=disabled" "-Dtools=enabled" "build"
    run $muon "-C" "build" samu $jobs_flag

    env ({
      DESTDIR: dest,
    }) {
      run $muon "-C" "build" install
    }
  }

  for bin in ["fc-cat", "fc-conflist", "fc-genconf", "fc-list", "fc-pattern", "fc-query", "fc-scan", "fc-validate"] {
    fp"{dest}/usr/bin/{bin}".remove(missing_ok: true)
  }

  # The links are relative to /etc/fonts/conf.d, as upstream's link_confs.py
  # makes them, so they resolve in any root the package is installed into.
  for conf in conf_links {
    fp"{dest}/etc/fonts/conf.d/{conf}".symlink(to: fp"../../../usr/share/fontconfig/conf.avail/{conf}")
  }

  fp"{dest}/usr/share/man".remove(missing_ok: true)
  fp"{dest}/usr/share/gettext".remove(missing_ok: true)
}
