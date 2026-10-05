##! Package recipe metadata and build operations.
use pm.make
use pm.util as pm_util

## Package recipe export.
export const name = "libnftnl"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.3.2"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl", "libmnl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "linux-headers", "pkgconf"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://www.netfilter.org/projects/libnftnl/files/libnftnl-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "c97abc3409f8fa396b4462b2bb7f147a3a47a4ddc97cfa0b2f18890c9cfde8b0",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/include/libnftnl",
    kind: "tree",
  },
  {
    path: p"usr/lib/libnftnl.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libnftnl.so.11",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libnftnl.so.11.8.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libnftnl.pc",
    kind: "file",
  },
]

# include/libnftnl/Makefile.am pkginclude_HEADERS.
pure public_headers() -> List[Str] {
  """
batch.h table.h trace.h chain.h object.h rule.h expr.h set.h flowtable.h
ruleset.h common.h udata.h gen.h
""".words()
}

# src/Makefile.am libnftnl_la_SOURCES, in upstream order.
pure library_sources() -> List[Str] {
  """
utils.c batch.c flowtable.c common.c gen.c table.c trace.c chain.c object.c
rule.c set.c set_elem.c str_array.c ruleset.c udata.c expr.c expr_ops.c
expr/bitwise.c expr/byteorder.c expr/cmp.c expr/range.c expr/connlimit.c
expr/counter.c expr/ct.c expr/data_reg.c expr/dup.c expr/exthdr.c
expr/flow_offload.c expr/fib.c expr/fwd.c expr/last.c expr/limit.c expr/log.c
expr/lookup.c expr/dynset.c expr/immediate.c expr/inner.c expr/match.c
expr/meta.c expr/numgen.c expr/nat.c expr/tproxy.c expr/objref.c
expr/payload.c expr/queue.c expr/quota.c expr/reject.c expr/rt.c
expr/target.c expr/tunnel.c expr/masq.c expr/redir.c expr/hash.c
expr/socket.c expr/synproxy.c expr/osf.c expr/xfrm.c
obj/counter.c obj/ct_helper.c obj/quota.c obj/tunnel.c obj/limit.c
obj/synproxy.c obj/ct_timeout.c obj/secmark.c obj/ct_expect.c obj/connlimit.c
""".words()
}

# Captured from upstream `./configure --prefix=/usr` (libmnl found through
# pkg-config) on an x86_64 musl host, then trimmed to what the sources read:
# only include/utils.h includes config.h, and it consults
# HAVE_VISIBILITY_HIDDEN to mark the exported symbols.
proc write_config_h() [fs, error] {
  fs.write(
    p"config.h",
    """#ifndef LIBNFTNL_CONFIG_H
#define LIBNFTNL_CONFIG_H
#define HAVE_VISIBILITY_HIDDEN 1
#endif
""",
  )
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let triple = f"{pm_util.target_arch()?}-linux-musl"
  let mnl = make.pkg_config_flags(["libmnl"])?
  write_config_h()

  # Flags from configure.ac (regular_CPPFLAGS, regular_CFLAGS, and the
  # -fvisibility=hidden that CHECK_GCC_FVISIBILITY adds) and Make_global.am.
  let libnftnl = make.c_shared_library({
    cc,
    triple,
    cflags: [
      "-O2",
      "-Wall",
      "-Waggregate-return",
      "-Wmissing-declarations",
      "-Wmissing-prototypes",
      "-Wshadow",
      "-Wstrict-prototypes",
      "-Wformat=2",
      "-Wwrite-strings",
      "-fvisibility=hidden",
    ].extend(mnl.cflags),
    defs: ["-DHAVE_CONFIG_H", "-D_FILE_OFFSET_BITS=64", "-D_REENTRANT"],
    includes: ["-I.", "-Iinclude"],
    root: p"src",
    sources: [fp"{source}" for source in library_sources()],
    out_dir: p"obj",
    # libtool -version-info 19:0:8 names the file libnftnl.so.11.8.0.
    out: p"obj/libnftnl.so.11.8.0",
    soname: "libnftnl.so.11",
    ldflags: ["-Wl,--version-script=src/libnftnl.map"].extend(mnl.libs),
    deps: [],
  })

  make.run_tasks(libnftnl.tasks, make.jobs()?)
  fs.install(libnftnl.output, fp"{dest}/usr/lib/libnftnl.so.11.8.0", 0o755, parents: true, overwrite: true)
  fs.symlink(p"libnftnl.so.11.8.0", fp"{dest}/usr/lib/libnftnl.so.11")
  fs.symlink(p"libnftnl.so.11.8.0", fp"{dest}/usr/lib/libnftnl.so")

  for header in public_headers() {
    fs.install(
      fp"include/libnftnl/{header}",
      fp"{dest}/usr/include/libnftnl/{header}",
      0o644,
      parents: true,
      overwrite: true,
    )
  }

  fs.mkdir(fp"{dest}/usr/lib/pkgconfig")

  # libnftnl.pc.in with configure's /usr prefix substituted.
  fs.write(
    fp"{dest}/usr/lib/pkgconfig/libnftnl.pc",
    f"""prefix=/usr
exec_prefix=${{prefix}}
libdir=${{exec_prefix}}/lib
includedir=${{prefix}}/include

Name: libnftnl
Description: Netfilter nf_tables infrastructure library
URL: http://netfilter.org/projects/libnftnl/
Version: {ver}
Requires:
Requires.private: libmnl
Conflicts:
Libs: -L${{libdir}} -lnftnl
Cflags: -I${{includedir}}
""",
  )
}
