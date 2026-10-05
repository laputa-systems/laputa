##! Package recipe metadata and build operations.
use pm.configure
use pm.make
use pm.util as pm_util

## Package recipe export.
export const name = "pkgconf"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "3.0.7"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://distfiles.ariadne.space/pkgconf/pkgconf-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "c926ff491cbd9a331a589160811bd97ab1749b4d5198a519338f2cdfabe6940a",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/bin/bomtool",
    kind: "binary",
  },
  {
    path: p"usr/bin/pccritic",
    kind: "binary",
  },
  {
    path: p"usr/bin/pkg-config",
    kind: "symlink",
  },
  {
    path: p"usr/bin/pkgconf",
    kind: "binary",
  },
  {
    path: p"usr/bin/spdxtool",
    kind: "binary",
  },
  {
    path: p"usr/include/pkgconf/libpkgconf/bsdstubs.h",
    kind: "file",
  },
  {
    path: p"usr/include/pkgconf/libpkgconf/iter.h",
    kind: "file",
  },
  {
    path: p"usr/include/pkgconf/libpkgconf/libpkgconf-api.h",
    kind: "file",
  },
  {
    path: p"usr/include/pkgconf/libpkgconf/libpkgconf.h",
    kind: "file",
  },
  {
    path: p"usr/include/pkgconf/libpkgconf/stdinc.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libpkgconf.a",
    kind: "file",
  },
  {
    path: p"usr/lib/libpkgconf.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libpkgconf.so.8",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libpkgconf.so.8.0.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libpkgconf.pc",
    kind: "file",
  },
  {
    path: p"usr/share/doc/pkgconf/COPYING",
    kind: "file",
  },
]

# Makefile.am's `-export-symbols-regex '^pkgconf_'`: libtool turns it into a
# version script, so the shared library exports only the public API.
const libpkgconf_version_script = """{
  global:
    pkgconf_*;
  local:
    *;
};
"""

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let arch = pm_util.target_arch()?
  let triple = f"{arch}-linux-musl"

  # Step 1: generate libpkgconf/config.h from autoheader's config.h.in.
  # Values are those configure (--prefix=/usr --sysconfdir=/etc) detects for
  # Clang + musl on aarch64 and x86_64: every probed declaration exists except
  # OpenBSD's pledge and unveil. 64-bit musl needs no _FILE_OFFSET_BITS.
  var defines: Map[Str] = {}
  defines["HAVE_DECL_GETC_UNLOCKED"] = "1"
  defines["HAVE_DECL_MKDTEMP"] = "1"
  defines["HAVE_DECL_NL_LANGINFO_L"] = "1"
  defines["HAVE_DECL_PLEDGE"] = "0"
  defines["HAVE_DECL_READLINKAT"] = "1"
  defines["HAVE_DECL_REALLOCARRAY"] = "1"
  defines["HAVE_DECL_STRNDUP"] = "1"
  defines["HAVE_DECL_UNVEIL"] = "0"
  defines["HAVE_DLFCN_H"] = "1"
  defines["HAVE_INTTYPES_H"] = "1"
  defines["HAVE_STDINT_H"] = "1"
  defines["HAVE_STDIO_H"] = "1"
  defines["HAVE_STDLIB_H"] = "1"
  defines["HAVE_STRINGS_H"] = "1"
  defines["HAVE_STRING_H"] = "1"
  defines["HAVE_SYS_STAT_H"] = "1"
  defines["HAVE_SYS_TYPES_H"] = "1"
  defines["HAVE_UNISTD_H"] = "1"
  defines["LT_OBJDIR"] = "\".libs/\""
  defines["PACKAGE"] = "\"pkgconf\""
  defines["PACKAGE_BUGREPORT"] = "\"https://github.com/pkgconf/pkgconf/issues/new\""
  defines["PACKAGE_NAME"] = "\"pkgconf\""
  defines["PACKAGE_STRING"] = f"\"pkgconf {ver}\""
  defines["PACKAGE_TARNAME"] = "\"pkgconf\""
  defines["PACKAGE_URL"] = "\"\""
  defines["PACKAGE_VERSION"] = f"\"{ver}\""
  defines["STDC_HEADERS"] = "1"
  defines["VERSION"] = f"\"{ver}\""
  configure.config_h(p"libpkgconf/config.h.in", p"libpkgconf/config.h", defines)

  # configure's CFLAGS and CPPFLAGS.
  let cflags = ["-g", "-O2", "-Wall", "-Wextra", "-Wformat=2", "-std=c99"]

  # The search paths are AM_CFLAGS -D flags (not config.h) from configure's
  # defaults: PKG_DEFAULT_PATH is ${libdir}/pkgconfig:${datadir}/pkgconfig,
  # and PERSONALITY_PATH looks under both ${datadir} and ${sysconfdir}.
  let defs = [
    "-D_ATFILE_SOURCE",
    "-D_BSD_SOURCE",
    "-D_DARWIN_C_SOURCE",
    "-D_DEFAULT_SOURCE",
    "-D_POSIX_C_SOURCE=200809L",
    "-D_XOPEN_SOURCE=700",
    "-DPKG_DEFAULT_PATH=\"/usr/lib/pkgconfig:/usr/share/pkgconfig\"",
    "-DSYSTEM_INCLUDEDIR=\"/usr/include\"",
    "-DSYSTEM_LIBDIR=\"/usr/lib\"",
    "-DPERSONALITY_PATH=\"/usr/share/pkgconfig/personality.d:/etc/pkgconfig/personality.d\"",
  ]

  # -I. finds <libpkgconf/config.h>; each program's CPPFLAGS add -Ilibpkgconf,
  # -Icli, and its own directory.
  let includes = ["-I.", "-Ilibpkgconf", "-Icli"]
  p"obj".mkdir()
  p"obj/libpkgconf.map".write(libpkgconf_version_script)

  # Step 2: libpkgconf, shared and static. Sources from Makefile.am's
  # libpkgconf_la_SOURCES; -version-info 8:0:0 makes libpkgconf.so.8.0.0.
  let lib_srcs = [
    p"libpkgconf/argvsplit.c",
    p"libpkgconf/audit.c",
    p"libpkgconf/bsdstubs.c",
    p"libpkgconf/buffer.c",
    p"libpkgconf/bufferset.c",
    p"libpkgconf/bytecode.c",
    p"libpkgconf/cache.c",
    p"libpkgconf/client.c",
    p"libpkgconf/dependency.c",
    p"libpkgconf/fileio.c",
    p"libpkgconf/fragment.c",
    p"libpkgconf/license.c",
    p"libpkgconf/output.c",
    p"libpkgconf/parser.c",
    p"libpkgconf/path.c",
    p"libpkgconf/personality.c",
    p"libpkgconf/pkg.c",
    p"libpkgconf/queue.c",
    p"libpkgconf/tuple.c",
    p"libpkgconf/variable.c",
    p"libpkgconf/version.c",
  ]

  let lib = make.c_shared_library({
    cc,
    triple,
    cflags,
    defs,
    includes,
    root: p".",
    sources: lib_srcs,
    out_dir: p"obj",
    out: p"obj/libpkgconf.so.8.0.0",
    soname: "libpkgconf.so.8",
    ldflags: ["-Wl,--version-script,obj/libpkgconf.map"],
    deps: [],
  })

  let static_target = make.c_static_library({
    cc,
    triple,
    cflags,
    defs,
    includes,
    root: p".",
    sources: lib_srcs,
    out_dir: p"obj/static",
    out: p"obj/libpkgconf.a",
    deps: [],
  })

  # Step 3: the four programs from Makefile.am, each linked against the
  # static archive so they need no libpkgconf.so at run time.
  # cli/getopt_long.c is compiled once per program, as automake does.
  let programs = [
    {name: "pkgconf", sources: [p"cli/main.c", p"cli/core.c", p"cli/getopt_long.c", p"cli/renderer-msvc.c"], include: "-Icli"},
    {name: "bomtool", sources: [p"cli/bomtool/main.c", p"cli/getopt_long.c"], include: "-Icli/bomtool"},
    {
      name: "spdxtool",
      sources: [
        p"cli/spdxtool/main.c",
        p"cli/spdxtool/core.c",
        p"cli/spdxtool/software.c",
        p"cli/spdxtool/serialize.c",
        p"cli/spdxtool/simplelicensing.c",
        p"cli/spdxtool/util.c",
        p"cli/spdxtool/generate.c",
        p"cli/getopt_long.c",
      ],
      include: "-Icli/spdxtool",
    },
    {name: "pccritic", sources: [p"cli/pccritic/main.c", p"cli/pccritic/critic.c", p"cli/getopt_long.c"], include: "-Icli/pccritic"},
  ]

  var tasks = lib.tasks.extend(static_target.tasks)
  var outputs: List[Path] = []

  for program in programs {
    let target = make.c_program({
      cc,
      triple,
      cflags,
      defs,
      includes: includes.push(program.include),
      root: p".",
      sources: program.sources,
      out_dir: fp"obj/{program.name}-objs",
      out: fp"obj/{program.name}",
      libs: [static_target.output],
      ldflags: [],
      deps: static_target.deps,
    })

    tasks += target.tasks
    outputs += [target.output]
  }

  make.run_tasks(tasks, make.jobs()?)

  # Step 4: install into dest.
  fs.install(lib.output, fp"{dest}/usr/lib/libpkgconf.so.8.0.0", 0o755, parents: true, overwrite: true)
  fp"{dest}/usr/lib/libpkgconf.so.8".symlink(to: p"libpkgconf.so.8.0.0")
  fp"{dest}/usr/lib/libpkgconf.so".symlink(to: p"libpkgconf.so.8.0.0")
  fs.install(static_target.output, fp"{dest}/usr/lib/libpkgconf.a", 0o644, parents: true, overwrite: true)

  for output in outputs {
    fs.install(output, fp"{dest}/usr/bin/{output.name}", 0o755, parents: true, overwrite: true)
  }

  fp"{dest}/usr/bin/pkg-config".symlink(to: p"pkgconf")

  # Makefile.am's nobase_pkginclude_HEADERS; config.h and the Windows
  # dirent shim stay private to the build.
  for hdr in ["bsdstubs.h", "iter.h", "libpkgconf.h", "stdinc.h", "libpkgconf-api.h"] {
    fs.install(fp"libpkgconf/{hdr}", fp"{dest}/usr/include/pkgconf/libpkgconf/{hdr}", 0o644, parents: true, overwrite: true)
  }

  # libpkgconf.pc names its license file, which dist_doc_DATA installs.
  configure.substitute(
    p"libpkgconf.pc.in",
    fp"{dest}/usr/lib/pkgconfig/libpkgconf.pc",
    [
      ["prefix", "/usr"],
      ["includedir", "/usr/include"],
      ["libdir", "/usr/lib"],
      ["datarootdir", "/usr/share"],
      ["datadir", "/usr/share"],
      ["PACKAGE_VERSION", ver],
    ],
  )

  fs.install(p"COPYING", fp"{dest}/usr/share/doc/pkgconf/COPYING", 0o644, parents: true, overwrite: true)
}
