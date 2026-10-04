##! Package recipe metadata and build operations.
use pm.make as make
use pm.util as pm_util

## Package recipe export.
export const name = "libmnl"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.0.5"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "linux-headers"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://www.netfilter.org/projects/libmnl/files/libmnl-VERSION.tar.bz2",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "274b9b919ef3152bfb3da3a13c950dd60d6e2bcd54230ffeca298d03b40d0525",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/include/libmnl/libmnl.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libmnl.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libmnl.so.0",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libmnl.so.0.2.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libmnl.pc",
    kind: "file",
  },
]

# Captured from upstream `./configure --prefix=/usr --with-doxygen=no` on an
# x86_64 musl host, then trimmed to what the sources read: only
# src/internal.h includes config.h, and it consults HAVE_VISIBILITY_HIDDEN to
# mark the exported symbols. The header checks and PACKAGE_* strings are unused.
proc write_config_h() [fs, error] {
  fs.write(
    p"config.h",
    """#ifndef LIBMNL_CONFIG_H
#define LIBMNL_CONFIG_H
#define HAVE_VISIBILITY_HIDDEN 1
#endif
""",
  )?
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let triple = f"{pm_util.target_arch()?}-linux-musl"
  write_config_h()?

  # Flags from configure.ac (regular_CPPFLAGS, regular_CFLAGS, and the
  # -fvisibility=hidden that CHECK_GCC_FVISIBILITY adds) and Make_global.am.
  let libmnl = make.c_shared_library({
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
      "-fvisibility=hidden",
    ],
    defs: ["-DHAVE_CONFIG_H", "-D_FILE_OFFSET_BITS=64", "-D_REENTRANT"],
    includes: ["-I.", "-Iinclude"],
    root: p".",
    # src/Makefile.am libmnl_la_SOURCES.
    sources: [p"src/socket.c", p"src/callback.c", p"src/nlmsg.c", p"src/attr.c"],
    out_dir: p"obj",
    # libtool -version-info 2:0:2 names the file libmnl.so.0.2.0.
    out: p"obj/libmnl.so.0.2.0",
    soname: "libmnl.so.0",
    ldflags: ["-Wl,--version-script=src/libmnl.map"],
    deps: [],
  })

  make.run_tasks(libmnl.tasks, make.jobs()?)?
  fs.install(libmnl.output, fp"{dest}/usr/lib/libmnl.so.0.2.0", 0o755, parents: true, overwrite: true)?
  fs.symlink(p"libmnl.so.0.2.0", fp"{dest}/usr/lib/libmnl.so.0")?
  fs.symlink(p"libmnl.so.0.2.0", fp"{dest}/usr/lib/libmnl.so")?
  # include/libmnl/Makefile.am pkginclude_HEADERS; include/linux/ is noinst.
  fs.install(p"include/libmnl/libmnl.h", fp"{dest}/usr/include/libmnl/libmnl.h", 0o644, parents: true, overwrite: true)?
  fs.mkdir(fp"{dest}/usr/lib/pkgconfig")?

  # libmnl.pc.in with configure's /usr prefix substituted.
  fs.write(
    fp"{dest}/usr/lib/pkgconfig/libmnl.pc",
    f"""prefix=/usr
exec_prefix=${{prefix}}
libdir=${{exec_prefix}}/lib
includedir=${{prefix}}/include

Name: libmnl
Description: Minimalistic Netlink communication library
URL: http://netfilter.org/projects/libmnl/
Version: {ver}
Requires:
Conflicts:
Libs: -L${{libdir}} -lmnl
Cflags: -I${{includedir}}
""",
  )?
}
