##! XSH module `PKGBUILD` package and build operations.
use pm.make
use pm.util as pm_util

## Exported declaration `name`.
export const name = "libffi"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "3.8.0"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "linux-headers"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://github.com/libffi/libffi/releases/download/vVERSION/libffi-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "7da3e2d9a171eb0a038f592ecad3ff2bb2550f3496d87b3b29ad0cf4430c0db4",
      },
    ],
  },
]

type LibffiTarget = {target: Str, dir: Str, sources: List[Str]}

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/include/ffi.h",
    kind: "file",
  },
  {
    path: p"usr/include/ffitarget.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libffi.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libffi.so.8",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libffi.so.8.5.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libffi.pc",
    kind: "file",
  },
]

pure libffi_target(machine: Str) -> LibffiTarget {
  if machine == "x86_64" {
    return {
      target: "X86_64",
      dir: "x86",
      sources: [
        "src/x86/ffi64.c",
        "src/x86/unix64.S",
        "src/x86/ffiw64.c",
        "src/x86/win64.S",
      ],
    }
  }

  {target: "AARCH64", dir: "aarch64", sources: ["src/aarch64/ffi.c", "src/aarch64/sysv.S"]}
}

# configure.ac encodes X.Y.Z as X*10000 + Y*100 + Z.
proc ffi_version_number() -> Result[Int] {
  let parts = ver.split(".")
  parts[0] as Int * 10000 + parts[1] as Int * 100 + parts[2] as Int
}

proc write_generated_headers(target: LibffiTarget) {
  let target_defines = if target.target == "X86_64" {
    """#define HAVE_AS_X86_PCREL 1
#define HAVE_AS_X86_64_UNWIND_SECTION_TYPE 1
"""
  } else {
    ""
  }

  p"fficonfig.h".write(
    f"""#ifndef FFICONFIG_H
#define FFICONFIG_H

#define EH_FRAME_FLAGS "a"
#define FFI_EXEC_STATIC_TRAMP 1
#define HAVE_ALLOCA_H 1
#define HAVE_AS_CFI_PSEUDO_OP 1
#define HAVE_DLFCN_H 1
#define HAVE_HIDDEN_VISIBILITY_ATTRIBUTE 1
#define HAVE_INT128 1
#define HAVE_INTTYPES_H 1
#define HAVE_LONG_DOUBLE 1
#define HAVE_MEMCPY 1
#define HAVE_MEMFD_CREATE 1
#define HAVE_RO_EH_FRAME 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
{target_defines}#define LIBFFI_GNU_SYMBOL_VERSIONING 1
#define LT_OBJDIR ".libs/"
#define PACKAGE "libffi"
#define PACKAGE_BUGREPORT "http://github.com/libffi/libffi/issues"
#define PACKAGE_NAME "libffi"
#define PACKAGE_STRING "libffi {ver}"
#define PACKAGE_TARNAME "libffi"
#define PACKAGE_URL ""
#define PACKAGE_VERSION "{ver}"
#define SIZEOF_DOUBLE 8
#define SIZEOF_LONG_DOUBLE 16
#define SIZEOF_SIZE_T 8
#define STDC_HEADERS 1
#define VERSION "{ver}"

#ifdef HAVE_HIDDEN_VISIBILITY_ATTRIBUTE
#ifdef LIBFFI_ASM
#ifdef __APPLE__
#define FFI_HIDDEN(name) .private_extern name
#else
#define FFI_HIDDEN(name) .hidden name
#endif
#else
#define FFI_HIDDEN __attribute__ ((visibility ("hidden")))
#endif
#else
#ifdef LIBFFI_ASM
#define FFI_HIDDEN(name)
#else
#define FFI_HIDDEN
#endif
#endif

#endif
""",
  )

  let ffi_h = p"include/ffi.h.in".read_text()?.replace("@VERSION@", with: ver).replace("@TARGET@", with: target.target)
    .replace("@HAVE_LONG_DOUBLE@", with: "1")
    .replace("@HAVE_LONG_DOUBLE_VARIANT@", with: "0")
    .replace("@FFI_VERSION_STRING@", with: ver)
    .replace("@FFI_VERSION_NUMBER@", with: f"{ffi_version_number()?}")
    .replace("@FFI_EXEC_TRAMPOLINE_TABLE@", with: "0")

  p"include/ffi.h".write(ffi_h)
  fs.install(fp"src/{target.dir}/ffitarget.h", p"include/ffitarget.h", 0o644, parents: true, overwrite: true)
}

# Upstream's Makefile preprocesses libffi.map.in against fficonfig.h and the
# target's ffitarget.h, which select the closure, Go closure, complex, and
# int128 symbol nodes the target exports.
proc write_version_script(cc: Path, triple: Str, target: LibffiTarget, defs: List[Str], includes: List[Str]) {
  let argv = ["-target", triple].extend(defs).extend(includes).extend([
    f"-D{target.target}",
    "-DGENERATE_LIBFFI_MAP",
    "-E",
    "-P",
    "-x",
    "assembler-with-cpp",
    "-o",
    "libffi.map",
    "libffi.map.in",
  ])

  run $cc ${argv}
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let arch = pm_util.target_arch()?
  let triple = f"{arch}-linux-musl"
  let target = libffi_target(arch)
  let cflags = ["-O2", "-Wall", "-fexceptions"]
  let defs = ["-DHAVE_CONFIG_H"]
  let includes = ["-I.", "-Iinclude", "-Isrc"]

  let srcs = ["src/prep_cif.c", "src/types.c", "src/raw_api.c", "src/java_raw_api.c", "src/closures.c", "src/tramp.c"].extend(
    target.sources,
  )

  write_generated_headers(target)
  write_version_script(cc, triple, target, defs, includes)

  let libffi = make.c_shared_library({
    cc,
    triple,
    cflags,
    defs,
    includes,
    root: p".",
    sources: [fp"{src}" for src in srcs],
    out_dir: p"obj",
    out: p"obj/libffi.so.8.5.0",
    soname: "libffi.so.8",
    ldflags: ["-Wl,--version-script,libffi.map"],
    deps: [],
  })

  make.run_tasks(libffi.tasks, make.jobs()?)
  fs.install(libffi.output, fp"{dest}/usr/lib/libffi.so.8.5.0", 0o755, parents: true, overwrite: true)
  fp"{dest}/usr/lib/libffi.so.8".symlink(to: p"libffi.so.8.5.0")
  fp"{dest}/usr/lib/libffi.so".symlink(to: p"libffi.so.8.5.0")
  # include/Makefile.am installs only the generated ffi.h and the target's
  # ffitarget.h; the other headers there are private to the build.
  fs.install(p"include/ffi.h", fp"{dest}/usr/include/ffi.h", 0o644, parents: true, overwrite: true)
  fs.install(p"include/ffitarget.h", fp"{dest}/usr/include/ffitarget.h", 0o644, parents: true, overwrite: true)
  fp"{dest}/usr/lib/pkgconfig".mkdir()

  fp"{dest}/usr/lib/pkgconfig/libffi.pc".write(
    f"""prefix=/usr
exec_prefix=${{prefix}}
libdir=${{exec_prefix}}/lib
includedir=${{prefix}}/include

Name: libffi
Description: Library supporting Foreign Function Interfaces
Version: {ver}
Libs: -L${{libdir}} -lffi
Cflags: -I${{includedir}}
""",
  )
}
