##! Package recipe metadata and build operations.
use pm.make
use pm.util as pm_util

## Package recipe export.
export const name = "nftables"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.1.7"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl", "libmnl", "libnftnl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "linux-headers", "pkgconf"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://www.netfilter.org/projects/nftables/files/nftables-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "a6fbf060d8d4fff001517a2b94f356bb4366bfbf0ba366366f9d27cc38caa58f",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/bin/nft",
    kind: "binary",
  },
  {
    path: p"usr/include/nftables/libnftables.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libnftables.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libnftables.so.1",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libnftables.so.1.1.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libnftables.pc",
    kind: "file",
  },
]

# Makefile.am src_libnftables_la_SOURCES with BUILD_JSON and BUILD_PROFILING
# off; src/xt.c is always listed and compiles to stubs without libxtables.
pure library_sources() -> List[Str] {
  """
src/cache.c src/cmd.c src/ct.c src/datatype.c src/dccpopt.c src/erec.c
src/evaluate.c src/expression.c src/exthdr.c src/fib.c src/gmputil.c
src/hash.c src/iface.c src/intervals.c src/ipopt.c src/libnftables.c
src/mergesort.c src/meta.c src/misspell.c src/mnl.c src/monitor.c
src/trace.c src/netlink.c src/netlink_delinearize.c src/netlink_linearize.c
src/nfnl_osf.c src/nftutils.c src/numgen.c src/optimize.c src/osf.c
src/owner.c src/payload.c src/preprocess.c src/print.c src/proto.c src/rt.c
src/rule.c src/sctp_chunk.c src/segtree.c src/socket.c src/statement.c
src/tcpopt.c src/tunnel.c src/utils.c src/xfrm.c src/xt.c
""".words()
}

# Makefile.am src_libparser_la_SOURCES. The release tarball ships the Bison
# parser (src/parser_bison.c and .h, Bison 3.8.2) and the Flex scanner
# (src/scanner.c) newer than their .y and .l sources, so configure takes the
# prebuilt path and neither generator runs.
const parser_sources = ["src/parser_bison.c", "src/scanner.c"]

# Makefile.am AM_CFLAGS.
pure warning_flags() -> List[Str] {
  """
-Wall -Waggregate-return -Wbad-function-cast -Wcast-align
-Wdeclaration-after-statement -Wformat-nonliteral -Wformat-security
-Winit-self -Wmissing-declarations -Wmissing-format-attribute
-Wmissing-prototypes -Wsign-compare -Wstrict-prototypes -Wundef -Wunused
-Wwrite-strings
""".words()
}

# configure substitutes BUILD_STAMP from SOURCE_DATE_EPOCH or the build time,
# and nft stamps it into the tables it creates to warn when a table came from
# a newer build of the same version. The newest file mtime in the 1.1.7 release
# tarball (src/scanner.c) keeps the payload reproducible; update it with `ver`.
const build_stamp = "1788280583"

# Captured from upstream `./configure --prefix=/usr --sysconfdir=/etc
# --with-mini-gmp --without-cli --without-json --disable-man-doc
# --disable-debug` (libmnl and libnftnl found through pkg-config) on an x86_64
# musl host, then trimmed to the macros the sources read: the fuzzer switch
# (tested with #if under -Wundef), the netdb reentrant declarations
# src/nftutils.c selects on (musl declares only getservbyport_r), symbol
# visibility, and the --version strings. _GNU_SOURCE is what
# AC_USE_SYSTEM_EXTENSIONS enables on Linux.
proc write_config_h() [fs, error] {
  fs.write(
    p"config.h",
    f"""#ifndef NFTABLES_CONFIG_H
#define NFTABLES_CONFIG_H
#define HAVE_DECL_GETPROTOBYNAME_R 0
#define HAVE_DECL_GETPROTOBYNUMBER_R 0
#define HAVE_DECL_GETSERVBYPORT_R 1
#define HAVE_FUZZER_BUILD 0
#define HAVE_VISIBILITY_HIDDEN 1
#define PACKAGE_NAME "nftables"
#define PACKAGE_VERSION "{ver}"
#define RELEASE_NAME "Commodore Bullmoose #8"
#ifndef _GNU_SOURCE
# define _GNU_SOURCE 1
#endif
#endif
""",
  )
}

# nftversion.h.in with configure's NFT_VERSION (the version's dotted parts),
# STABLE_RELEASE (0 without --with-stable-release), and BUILD_STAMP.
proc write_nftversion_h() {
  let version_template = p"nftversion.h.in".read_text()?
  let body = version_template.replace("@BUILD_STAMP@", build_stamp).replace("@NFT_VERSION@", ver.replace(".", ",")).replace("@STABLE_RELEASE@", "0")
  fs.write(p"nftversion.h", body)
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let triple = f"{pm_util.target_arch()?}-linux-musl"
  let netfilter = make.pkg_config_flags(["libmnl", "libnftnl"])?
  write_config_h()
  write_nftversion_h()

  # Makefile.am AM_CPPFLAGS with BUILD_MINIGMP on and BUILD_DEBUG off.
  let cflags = ["-O2", @warning_flags(), "-fvisibility=hidden"]
  let defs = ["-DHAVE_CONFIG_H", "-DDEFAULT_INCLUDE_PATH=\"/etc\"", "-DHAVE_MINIGMP"]
  let includes = ["-I.", "-Iinclude"].extend(netfilter.cflags)

  let library = make.compile_lo_tasks(
    cc,
    triple,
    cflags,
    defs,
    includes,
    p".",
    [fp"{source}" for source in library_sources()],
    p"obj/libnftables",
  )

  # Makefile.am src_libparser_la_CFLAGS: generated code needs these relaxed.
  let parser = make.compile_lo_tasks(
    cc,
    triple,
    cflags.extend([
      "-Wno-missing-declarations",
      "-Wno-missing-prototypes",
      "-Wno-nested-externs",
      "-Wno-redundant-decls",
      "-Wno-undef",
      "-Wno-unused-but-set-variable",
    ]),
    defs,
    includes,
    p".",
    [fp"{source}" for source in parser_sources],
    p"obj/libparser",
  )

  # Makefile.am src_libminigmp_la_CFLAGS, built in place of libgmp.
  let minigmp = make.compile_lo_tasks(
    cc,
    triple,
    cflags.extend(["-Wno-sign-compare"]),
    defs,
    includes,
    p".",
    [p"src/mini-gmp.c"],
    p"obj/libminigmp",
  )

  # libtool -version-info 2:0:1 names the file libnftables.so.1.1.0. Upstream
  # links the parser and mini-gmp convenience libraries whole-archive, which
  # is the same as linking their objects directly.
  let library_so = p"obj/libnftables.so.1.1.0"

  let link_library = make.link_shared_task(
    cc,
    triple,
    library.objects.extend(parser.objects).extend(minigmp.objects),
    "libnftables.so.1",
    ["-Wl,--version-script=src/libnftables.map"].extend(netfilter.libs),
    library_so,
    library.deps.extend(parser.deps).extend(minigmp.deps),
  )

  # Makefile.am src_nft_SOURCES without BUILD_CLI, linked to libnftables.
  let nft = make.compile_c_tasks(cc, triple, cflags, defs, includes, p".", [p"src/main.c"], p"obj/nft")
  let nft_out = p"obj/nft/nft"
  let link_nft = make.link_executable_task(cc, triple, nft.objects, [library_so], [], nft_out, nft.deps.push(link_library.name))
  let tasks = library.tasks.extend(parser.tasks).extend(minigmp.tasks).push(link_library).extend(nft.tasks).push(link_nft)
  make.run_tasks(tasks, make.jobs()?)

  fs.install(nft_out, fp"{dest}/usr/bin/nft", 0o755, parents: true, overwrite: true)
  fs.install(library_so, fp"{dest}/usr/lib/libnftables.so.1.1.0", 0o755, parents: true, overwrite: true)
  fs.symlink(p"libnftables.so.1.1.0", fp"{dest}/usr/lib/libnftables.so.1")
  fs.symlink(p"libnftables.so.1.1.0", fp"{dest}/usr/lib/libnftables.so")

  fs.install(
    p"include/nftables/libnftables.h",
    fp"{dest}/usr/include/nftables/libnftables.h",
    0o644,
    parents: true,
    overwrite: true,
  )

  fs.mkdir(fp"{dest}/usr/lib/pkgconfig")

  # libnftables.pc.in with configure's /usr prefix substituted.
  fs.write(
    fp"{dest}/usr/lib/pkgconfig/libnftables.pc",
    f"""prefix=/usr
exec_prefix=${{prefix}}
libdir=${{exec_prefix}}/lib
includedir=${{prefix}}/include

Name: libnftables
Description: Netfilter nf_tables user library
URL: http://netfilter.org/projects/nftables/
Version: {ver}
Requires:
Conflicts:
Libs: -L${{libdir}} -lnftables
Cflags: -I${{includedir}}
""",
  )
}
