##! Package recipe metadata and build operations.
use pm.make
use pm.util as pm_util

## Package recipe export.
export const name = "libcap"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "2.78"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## The kernel capability header libcap builds against ships in its own
## `libcap/include/uapi`, so no linux-headers dependency is needed.
export const mkdeps_host = ["llvm-toolchain"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://cdn.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "0d621e562fd932ccf67b9660fb018e468a683d7b827541df27813228c996bb11",
      },
    ],
  },
]

## The programs install to /usr/bin (upstream's `sbindir=bin`), and only the
## shared library: libpsx is the POSIX-semantics setuid shim for Go and
## pthread programs, which nothing here needs with GOLANG=no.
export const filetree = [
  {
    path: p"usr/bin/capsh",
    kind: "binary",
  },
  {
    path: p"usr/bin/getcap",
    kind: "binary",
  },
  {
    path: p"usr/bin/getpcaps",
    kind: "binary",
  },
  {
    path: p"usr/bin/setcap",
    kind: "binary",
  },
  {
    path: p"usr/include/sys/capability.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libcap.so.2.78",
    kind: "binary",
  },
  {
    path: p"usr/lib/libcap.so.2",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libcap.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/pkgconfig/libcap.pc",
    kind: "file",
  },
]

# Make.Rules' CPPFLAGS (with lib=lib, prefix=/usr) and the library's own
# -D_LIBPSX_PTHREAD_LINKAGE; the bundled uapi header precedes the system's.
const cppflags = [
  "-Dlinux",
  "-D_LARGEFILE64_SOURCE",
  "-D_FILE_OFFSET_BITS=64",
  "-Ilibcap/include/uapi",
  "-Ilibcap/include",
]

const libcap_sources = [
  p"libcap/cap_alloc.c",
  p"libcap/cap_proc.c",
  p"libcap/cap_extint.c",
  p"libcap/cap_flag.c",
  p"libcap/cap_text.c",
  p"libcap/cap_file.c",
  p"libcap/cap_syscalls.c",
]

# The capability name generator, libcap/Makefile's cap_names.list.h rule:
#   grep -E '^#define\s+CAP_([^\s]+)\s+[0-9]+\s*$' include/uapi/linux/capability.h \
#   | sed -e 's/^#define\s\+/{"/' -e 's/\s*$/},/' -e 's/\s\+/",/' \
#         -e 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/'
# which turns `#define CAP_CHOWN 0` into `{"cap_chown",0},`.
const capability_define = rx"^#define\s+(CAP_[^\s]+)\s+([0-9]+)\s*$"

proc write_cap_names_list() {
  var out = ""

  for line in p"libcap/include/uapi/linux/capability.h".read_text()?.lines() {
    if let [_, cap, value] = capability_define.captures(line) {
      out = out + "{\"" + cap.lower() + "\"," + value + "},\n"
    }
  }

  fs.write(p"libcap/cap_names.list.h", out)
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let arch = pm_util.target_arch()?
  let build_arch = pm_util.build_arch()?
  let triple = f"{arch}-linux-musl"
  var build_cc = cc
  var build_task_env: Record = {}

  # _makenames runs here, so a cross build compiles it for the build machine.
  if build_arch != arch {
    let build_root = fp"{e"XSH_PM_BUILD_ROOT" ?? ""}"
    build_cc = fp"{build_root}/usr/bin/cc"

    build_task_env = {
      XSH_MAKE_NATIVE_CROSS: "0",
      PATH: f"{build_root}/usr/bin:{build_root}/usr/lib/llvm-toolchain/bin:{e"PATH" ?? ""}",
      LD_LIBRARY_PATH: f"{build_root}/usr/lib:{build_root}/usr/lib/llvm23/lib",
    }
  }

  write_cap_names_list()

  # cap_names.h is printed by _makenames, which tabulates the names above.
  let makenames = make.c_program({
    cc: build_cc,
    triple: f"{build_arch}-linux-musl",
    cflags: ["-O2"],
    defs: [],
    includes: cppflags,
    root: p".",
    sources: [p"libcap/_makenames.c"],
    out_dir: p"obj/makenames",
    out: p"obj/_makenames",
    libs: [],
    ldflags: [],
    deps: [],
  })

  make.run_tasks([{...task, env: build_task_env} for task in makenames.tasks], make.jobs()?)
  let makenames_bin = makenames.output
  fs.write(p"libcap/cap_names.h", run.text $makenames_bin ?)

  let lib_cflags = ["-O2", "-D_LIBPSX_PTHREAD_LINKAGE"]
  let objects = make.compile_lo_tasks(cc, triple, lib_cflags, [], cppflags, p".", libcap_sources, p"obj/libcap")

  # execable.c makes libcap.so.2 runnable: its .interp names the target's
  # musl loader (upstream copies it from an empty program's .interp), and
  # `__so_start` prints the library version when the file is executed.
  let magic = make.compile_lo_task(
    cc,
    triple,
    lib_cflags,
    [f"-DLIBRARY_VERSION=\"libcap-{ver}\"", f"-DSHARED_LOADER=\"/lib/ld-musl-{arch}.so.1\""],
    [@cppflags, "-include", "libcap/libcap.h"],
    p"libcap/execable.c",
    p"obj/libcap/cap_magic.lo",
  )

  let soname = "libcap.so.2"
  let library = p"obj/libcap.so.2.78"

  let link = make.link_shared_task(
    cc,
    triple,
    [@objects.objects, @magic.outputs],
    soname,
    ["-Wl,-x", "-Wl,-e,__so_start"],
    library,
    [@objects.deps, magic.name],
  )

  # Programs link the shared library, as upstream's SHARED=yes build does.
  let progs_deps = [link.name]

  var prog_tasks: List[make.MakeTask] = []

  for prog in ["getcap", "getpcaps", "setcap"] {
    let program = make.c_program({
      cc,
      triple,
      cflags: ["-O2"],
      defs: [],
      includes: cppflags,
      root: p".",
      sources: [fp"progs/{prog}.c"],
      out_dir: fp"obj/{prog}",
      out: fp"obj/{prog}-bin",
      libs: [library],
      ldflags: [],
      deps: progs_deps,
    })

    prog_tasks = [@prog_tasks, @program.tasks]
  }

  # capsh execs its SHELL for `--` and `==`; Laputa's interactive shell is
  # xshi, not upstream's /bin/bash default.
  let capsh = make.c_program({
    cc,
    triple,
    cflags: ["-O2"],
    defs: ["-DSHELL=\"/bin/xshi\""],
    includes: cppflags,
    root: p".",
    sources: [p"progs/capsh.c", p"progs/capshdoc.c"],
    out_dir: p"obj/capsh",
    out: p"obj/capsh-bin",
    libs: [library],
    ldflags: [],
    deps: progs_deps,
  })

  make.run_tasks([@objects.tasks, magic, link, @capsh.tasks, @prog_tasks], make.jobs()?)

  let bindir = fp"{dest}/usr/bin"
  fs.mkdir(bindir, parents: true)

  for prog in ["getcap", "getpcaps", "setcap", "capsh"] {
    fs.install(fp"obj/{prog}-bin", fp"{bindir}/{prog}", 0o755, overwrite: true)
  }

  let libdir = fp"{dest}/usr/lib"
  fs.install(library, fp"{libdir}/libcap.so.2.78", 0o755, parents: true, overwrite: true)
  fs.symlink(p"libcap.so.2.78", fp"{libdir}/libcap.so.2")
  fs.symlink(p"libcap.so.2", fp"{libdir}/libcap.so")
  fs.install(p"libcap/include/sys/capability.h", fp"{dest}/usr/include/sys/capability.h", 0o644, parents: true, overwrite: true)

  # libcap.pc.in with the substitutions libcap/Makefile applies; @deps@ is
  # empty because the library links nothing beyond libc.
  let pc = p"libcap/libcap.pc.in".read_text()?
    .replace("@prefix@", "/usr")
    .replace("@exec_prefix@", "/usr")
    .replace("@libdir@", "/usr/lib")
    .replace("@includedir@", "/usr/include")
    .replace("@VERSION@", ver)
    .replace("@deps@", "")

  fs.mkdir(fp"{libdir}/pkgconfig")
  fs.write(fp"{libdir}/pkgconfig/libcap.pc", pc)
}
