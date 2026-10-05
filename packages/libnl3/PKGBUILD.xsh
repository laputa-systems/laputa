##! XSH module `PKGBUILD` package and build operations.
use pm.make
use pm.util as pm_util

## Exported declaration `name`.
export const name = "libnl3"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "3.12.0"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "linux-headers"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://github.com/thom311/libnl/releases/download/libnl3_12_0/libnl-3.12.0.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "fc51ca7196f1a3f5fdf6ffd3864b50f4f9c02333be28be4eeca057e103c0dd18",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr",
    kind: "tree",
  },
  {
    path: p"usr/lib/libnl-3.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libnl-3.so.200",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libnl-3.so.200.26.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/libnl-genl-3.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libnl-genl-3.so.200",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libnl-genl-3.so.200.26.0",
    kind: "binary",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cwd = fs.cwd()?
  let src = cwd
  let objs = p"objs"
  fs.mkdir(objs)

  # Generate include/netlink/version.h from version.h.in
  fs.mkdir(fp"{src}/include/netlink")
  let version_h = fp"{src}/include/netlink/version.h"
  let version_in = fp"{src}/include/netlink/version.h.in"

  if ! fs.exists(version_h)? and fs.exists(version_in)? {
    let tmpl = fs.read_text(version_in)?
    let parts = ver.split(".")
    let major = parts[0]
    let minor = if parts.len() > 1 { parts[1] } else { "0" }
    let micro = if parts.len() > 2 { parts[2] } else { "0" }

    let body = tmpl.replace("@MAJOR_VERSION@", major)
      .replace("@MINOR_VERSION@", minor)
      .replace("@MICRO_VERSION@", micro)

    fs.write(version_h, body)
  }

  # include/config.h as configure writes it for musl: the keys are exactly
  # those of include/config.h.in. musl declares neither getprotobyname_r nor
  # getprotobynumber_r, so utils.c takes its non-reentrant fallback; pthreads
  # live in libc.
  let config_h = fp"{src}/include/config.h"

  if ! fs.exists(config_h)? {
    let cfg_body = f"""#ifndef LIBNL_CONFIG_H
#define LIBNL_CONFIG_H
#define HAVE_DECL_GETPROTOBYNAME_R 0
#define HAVE_DECL_GETPROTOBYNUMBER_R 0
#define HAVE_DLFCN_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIBPTHREAD 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRERROR_L 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_WCHAR_H 1
#define NL_DEBUG 0
#define PACKAGE "libnl"
#define PACKAGE_BUGREPORT ""
#define PACKAGE_NAME "libnl"
#define PACKAGE_STRING "libnl {ver}"
#define PACKAGE_TARNAME "libnl"
#define PACKAGE_URL "http://www.infradead.org/~tgr/libnl/"
#define PACKAGE_VERSION "{ver}"
#define STDC_HEADERS 1
#define VERSION "{ver}"
#endif
"""

    fs.write(config_h, cfg_body)
  }

  let cc = process.which("cc")?
  let triple = f"{pm_util.target_arch()?}-linux-musl"

  # Pre-create install directories.
  fs.mkdir(fp"{dest}/usr")
  fs.mkdir(fp"{dest}/usr/lib")
  fs.mkdir(fp"{dest}/usr/include")
  # Upstream compiles every library as gnu11 with the sysconfdir and pkglibdir
  # defines from Makefile.am's defines_cppflags.
  var cflags = ["-std=gnu11", "-O2", "-fPIC", "-DPIC", "-D_GNU_SOURCE"]
  var defs = ["-D_NL_SYSCONFDIR_LIBNL=\"/etc/libnl\"", "-D_NL_PKGLIBDIR=\"/usr/lib/libnl\""]

  var includes = [
    "-I",
    fp"{src}/include".display(),
    "-I",
    fp"{src}/include/linux-private".display(),
    "-I",
    fp"{src}/lib".display(),
    "-I",
    src.display(),
    "-I",
    fp"{src}/third_party/c-list/src".display(),
  ]

  # Core source files for libnl-3.so
  let core_sources = [
    p"lib/mpls.c",
    p"lib/addr.c",
    p"lib/attr.c",
    p"lib/cache.c",
    p"lib/cache_mngr.c",
    p"lib/cache_mngt.c",
    p"lib/data.c",
    p"lib/error.c",
    p"lib/handlers.c",
    p"lib/hash.c",
    p"lib/hashtable.c",
    p"lib/msg.c",
    p"lib/nl.c",
    p"lib/object.c",
    p"lib/socket.c",
    p"lib/utils.c",
    p"lib/version.c",
  ]

  # genl source files for libnl-genl-3.so
  let genl_sources = [p"lib/genl/ctrl.c", p"lib/genl/family.c", p"lib/genl/genl.c", p"lib/genl/mngt.c"]
  let core_so = fp"{dest}/usr/lib/libnl-3.so.200.26.0"
  let genl_so = fp"{dest}/usr/lib/libnl-genl-3.so.200.26.0"

  let core = make.c_shared_library({
    cc,
    triple,
    cflags,
    defs,
    includes,
    root: src,
    sources: core_sources,
    out_dir: objs,
    out: core_so,
    soname: "libnl-3.so.200",
    ldflags: [],
    deps: [],
  })

  let genl = make.c_shared_library({
    cc,
    triple,
    cflags,
    defs,
    includes,
    root: src,
    sources: genl_sources,
    out_dir: objs,
    out: genl_so,
    soname: "libnl-genl-3.so.200",
    ldflags: [],
    deps: [],
  })

  make.run_tasks(core.tasks.extend(genl.tasks), make.jobs()?)

  # Create symlinks
  for lib in [core_so, genl_so] {
    let basename = lib.name
    let parts = basename.split(".so.")
    let soname = f"{parts[0]}.so.{parts[1].split(".")[0]}"
    let linker = f"{parts[0]}.so"
    fs.symlink(fp"{basename}", fp"{dest}/usr/lib/{soname}")
    fs.symlink(fp"{soname}", fp"{dest}/usr/lib/{linker}")
  }

  # Install public headers at /usr/include/netlink/
  let usr_include = fp"{dest}/usr/include"
  fs.mkdir(usr_include)
  let headers_src = fp"{src}/include/netlink"
  let headers_dest = fp"{dest}/usr/include/netlink"
  make.install_header_tree(headers_src, headers_dest, [p"version.h.in"])
}
