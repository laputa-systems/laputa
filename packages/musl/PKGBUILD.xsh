##! musl libc package definition and build operations.
use pm.make
use pm.util as pm_util

error MuslError = Failed(message: Str)

## Package name.
export const name = "musl"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Upstream musl version.
export const ver = "1.2.6"

## Package release revision.
export const rel = "16"

## Runtime package dependencies.
export let deps = []

## Host-side build dependencies.
export const mkdeps_host = ["llvm-toolchain"]

## `ldd` is an XSH wrapper; it needs the `xsh` runner at runtime.
export const runtime_only_deps = ["xsh"]

## Preserve upstream binaries without stripping.
export const nostrip = true

## Upstream source archives and checksums.
export const upstream_sources = [
  {
    source: p"https://musl.libc.org/releases/musl-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a",
      },
      {
        arch: "x86_64",
        sha256: "d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a",
      },
    ],
  },
]

const filetree_common = [
  {
    path: p"usr",
    kind: "tree",
  },
  {
    path: p"usr/lib/Scrt1.o",
    kind: "binary",
  },
  {
    path: p"usr/lib/crt1.o",
    kind: "binary",
  },
  {
    path: p"usr/lib/crti.o",
    kind: "binary",
  },
  {
    path: p"usr/lib/crtn.o",
    kind: "binary",
  },
  {
    path: p"usr/lib/libc.so",
    kind: "binary",
  },
  {
    path: p"usr/lib/libcrypt.a",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libcrypt.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libdl.a",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libdl.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libm.a",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libm.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libpthread.a",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libpthread.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/librt.a",
    kind: "symlink",
  },
  {
    path: p"usr/lib/librt.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/rcrt1.o",
    kind: "binary",
  },
]

## Installed files for aarch64.
export let filetree_aarch64 = filetree_common.push({path: p"usr/lib/ld-musl-aarch64.so.1", kind: "symlink"})

## Installed files for x86_64.
export let filetree_x86_64 = filetree_common.push({path: p"usr/lib/ld-musl-x86_64.so.1", kind: "symlink"})

## Installed package file tree for the selected architecture.
export let filetree = filetree_aarch64

pure regex_captures(text: Str, pattern: Str) -> Result[List[Str]] {
  let re = regex.compile(pattern)?
  re.captures(text)
}

proc compiler_rt_builtins(arch: Str) [fs, error] -> Result[List[Path]] {
  let target_root = p"llvm-toolchain-target"

  let candidates = [
    fp"{target_root}/usr/lib/llvm23/lib/clang/23/lib/{arch}-linux-musl/libclang_rt.builtins-{arch}.a",
    fp"{target_root}/lib/llvm23/lib/clang/23/lib/{arch}-linux-musl/libclang_rt.builtins-{arch}.a",
    fp"/usr/lib/llvm23/lib/clang/23/lib/{arch}-linux-musl/libclang_rt.builtins-{arch}.a",
    fp"/usr/lib/llvm23/lib/clang/23/lib/linux/libclang_rt.builtins-{arch}.a",
    fp"/usr/lib/libclang_rt.builtins-{arch}.a",
  ]

  for candidate in candidates {
    return [candidate] when fs.exists(candidate)?
  }

  []
}

## Build and install the musl libc package.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let arch = pm_util.target_arch()?
  let triple = f"{arch}-linux-musl"

  # Generate include/bits/alltypes.h and include/bits/syscall.h.
  # bits/ does not exist in the source tree — create it first.
  fs.mkdir(p"include/bits")

  # Replicates tools/mkalltypes.sed.
  # Input: arch/ARCH/bits/alltypes.h.in then include/alltypes.h.in (concatenated).
  # TYPEDEF T name;  →  #if defined(__NEED_name) && !defined(__DEFINED_name)
  #                     typedef T name;
  #                     #define __DEFINED_name
  #                     #endif
  # STRUCT name body; and UNION name body; get equivalent struct/union wrappers.
  # All other lines (#define, #if, #endif, blank, etc.) pass through unchanged.
  let arch_at = fs.read_text(fp"arch/{arch}/bits/alltypes.h.in")?
  let generic_at = fs.read_text(p"include/alltypes.h.in")?
  var at_lines = []

  for line in [arch_at, generic_at].join("\n").split("\n") {
    if line.starts_with("TYPEDEF ") {
      let caps = regex_captures(line, "^TYPEDEF (.+) ([^ ]+);$")?
      let type_expr = caps[1]
      let type_name = caps[2]
      at_lines += [f"#if defined(__NEED_{type_name}) && !defined(__DEFINED_{type_name})"]
      at_lines += [f"typedef {type_expr} {type_name};"]
      at_lines += [f"#define __DEFINED_{type_name}"]
      at_lines += ["#endif"]
    } else if line.starts_with("STRUCT ") {
      let caps = regex_captures(line, "^STRUCT +([^ ]+) (.+);$")?
      let sname = caps[1]
      let sbody = caps[2]
      at_lines += [f"#if defined(__NEED_struct_{sname}) && !defined(__DEFINED_struct_{sname})"]
      at_lines += [f"struct {sname} {sbody};"]
      at_lines += [f"#define __DEFINED_struct_{sname}"]
      at_lines += ["#endif"]
    } else if line.starts_with("UNION ") {
      let caps = regex_captures(line, "^UNION +([^ ]+) (.+);$")?
      let uname = caps[1]
      let ubody = caps[2]
      at_lines += [f"#if defined(__NEED_union_{uname}) && !defined(__DEFINED_union_{uname})"]
      at_lines += [f"union {uname} {ubody};"]
      at_lines += [f"#define __DEFINED_union_{uname}"]
      at_lines += ["#endif"]
    } else {
      at_lines += [line]
    }
  }

  fs.write(p"include/bits/alltypes.h", at_lines.join("\n"))

  # Generate include/bits/syscall.h as musl's Makefile does: the __NR_* header
  # as is, then a SYS_* copy of each __NR_ line (`sed -n s/__NR_/SYS_/p`).
  # Programs use both names.
  let syscall_in = fs.read_text(fp"arch/{arch}/bits/syscall.h.in")?
  let sys_names = [line.replace("__NR_", "SYS_") for line in syscall_in.lines() if "__NR_" in line]
  let base = if syscall_in.ends_with("\n") { syscall_in } else { syscall_in + "\n" }
  fs.write(p"include/bits/syscall.h", base + sys_names.join("\n") + "\n")

  # Generate src/internal/version.h (included by src/internal/version.c).
  # configure normally produces this from tools/version.sh + VERSION file.
  fs.write(
    p"src/internal/version.h",
    f"""#define VERSION "{ver}"
""",
  )

  # Compilation flags matching musl configure output for Clang + musl targets.
  # -U_FORTIFY_SOURCE: Clang enables _FORTIFY_SOURCE by default, injecting
  #   LOCAL __memcpy_chk wrappers that shadow musl's assembly GLOBAL memcpy.
  # -fno-sanitize=all: UBSan instrumentation introduces HIDDEN memcpy references
  #   which ELF visibility merging demotes, poisoning musl's exported symbols.
  let cflags = [
    "-std=c99",
    "-nostdinc",
    "-ffreestanding",
    "-fexcess-precision=standard",
    "-frounding-math",
    "-Wa,--noexecstack",
    "-D_XOPEN_SOURCE=700",
    "-O2",
    "-pipe",
    "-U_FORTIFY_SOURCE",
    "-fno-sanitize=all",
  ]

  let includes = [f"-I./arch/{arch}", "-I./arch/generic", "-I./src/include", "-I./src/internal", "-I./include"]

  # Collect arch sources from two places, matching musl's Makefile:
  # 1. arch/${arch}/*.{c,s} — top-level arch files (empty for aarch64/x86_64)
  # 2. src/{subsystem}/${arch}/*.[csS] — in-source arch overrides (math, thread,
  #    signal, etc. optimised assembly/C for the target architecture)
  # An override replaces only the generic file at its own path, as the
  # Makefile's REPLACED_OBJS (`/$(ARCH)/` removed) does: src/thread/x86_64/clone.s
  # replaces src/thread/clone.c (__clone), never src/linux/clone.c (clone()).
  var replaced: List[Str] = []
  var arch_c_files = []
  var arch_s_files = []

  # 1. arch/${arch}/ direct children (headers only for aarch64/x86_64 in practice).
  for e in fs.children(fp"arch/{arch}")? |> where .kind == "file" {
    if e.ext == "c" {
      arch_c_files += [e.path]
    } else if e.ext == "s" or e.ext == "S" {
      arch_s_files += [e.path]
    }
  }

  # 2. src/{subsystem}/${arch}/*.[csS] — in-source arch overrides.
  for subsys in fs.children(p"src")? |> where .kind == "dir" {
    let arch_subdir = fp"{subsys.path}/{arch}"

    if fs.exists(arch_subdir)? {
      for e in fs.children(arch_subdir)? |> where .kind == "file" {
        if e.ext == "c" {
          replaced += [f"{subsys.name}/{e.name.replace(".c", "")}"]
          arch_c_files += [e.path]
        } else if e.ext == "s" or e.ext == "S" {
          replaced += [f"{subsys.name}/{e.name.replace(f".{e.ext}", "")}"]
          arch_s_files += [e.path]
        }
      }
    }
  }

  # Enumerate src/ .c files, matching musl's Makefile: SRC_DIRS = src/* (one
  # level deep per subsystem) plus src/malloc/mallocng (two levels, the default
  # malloc implementation), minus the generic files an arch override replaces.
  # fs.children is non-recursive here intentionally: src/{subsystem}/{arch}/*.c files
  # at two levels deep must not be included (they are wrong-arch implementations).
  var libc_srcs = [
    e.path
    for subsys in fs.children(p"src")? |> where .kind == "dir"
    for e in fs.children(subsys.path)? |> where .ext == "c"
    if ! (f"{subsys.name}/{e.name.replace(".c", "")}" in replaced)
  ]
  # src/malloc/mallocng/*.c — the default malloc implementation (two levels deep).
  for e in fs.children(p"src/malloc/mallocng")? |> where .ext == "c" {
    libc_srcs += [e.path]
  }

  fs.mkdir(p"obj")

  # Compile all src/ sources → LOBJS (PIC; go into both libc.a and libc.so).
  var tasks = []
  let libc = make.compile_lo_tasks(cc, triple, cflags, [], includes, p"", libc_srcs, p"obj/libc")
  tasks += libc.tasks

  # Compile arch/ C overrides → LOBJS.
  let arch_c = make.compile_lo_tasks(cc, triple, cflags, [], includes, p"", arch_c_files, p"obj/arch")
  tasks += arch_c.tasks
  var lobjs = libc.objects.extend(arch_c.objects)
  var lobj_deps = libc.deps.extend(arch_c.deps)

  # Compile arch/ assembly overrides → LOBJS (skip C-specific flags; include
  # paths still passed for any .S files that use the C preprocessor).
  let arch_asm = make.compile_asm_lo_tasks(cc, triple, includes, p"", arch_s_files, p"obj/arch-asm")
  tasks += arch_asm.tasks
  lobj_deps += arch_asm.deps
  lobjs += arch_asm.objects

  # Compile top-level ldso/ → LDSO_OBJS (PIC; libc.so only, not in libc.a).
  # ldso/dlstart.c defines _dlstart (ELF entry of libc.so / the dynamic linker).
  # ldso/dynlink.c is the main dynamic-linker implementation.
  # Hardcoded list — ldso/ contains exactly these two files in every musl release.
  var ldso_objs = []
  var ldso_deps = []
  fs.mkdir(p"obj/ldso")
  let ldso_sources = [fp"ldso/{src_name}.c" for src_name in ["dlstart", "dynlink"]]
  let ldso_compile = make.compile_lo_tasks(cc, triple, cflags, [], includes, p"", ldso_sources, p"obj/ldso")
  tasks += ldso_compile.tasks
  ldso_objs = ldso_compile.objects
  ldso_deps = ldso_compile.deps

  # libc.a — static archive from LOBJS only (ldso not needed for static linking).
  let libc_a = p"obj/libc.a"
  tasks += [make.link_archive_task(cc, lobjs, libc_a, lobj_deps)]

  # libc.so — LOBJS + LDSO_OBJS. musl's floating-point paths can use compiler-rt
  # helpers, so link the builtins archive after musl's own objects when it is
  # available and let the linker pull only unresolved helper objects.
  let libc_so = p"obj/libc.so"
  var all_so_objs = lobjs
  var all_so_deps = lobj_deps

  for obj in ldso_objs {
    all_so_objs += [obj]
  }

  all_so_deps += ldso_deps
  let builtins = compiler_rt_builtins(arch)?
  all_so_objs += builtins

  let so_ldflags = [
    "-shared",
    "-nostdlib",
    "-fno-sanitize=all",
    "-Wl,--sort-section,alignment",
    "-Wl,--sort-common",
    "-Wl,--hash-style=both",
    "-Wl,-e,_dlstart",
  ]

  var so_argv: List[Any] = [cc, "-target", triple]
  so_argv = [@so_argv, @so_ldflags]

  for obj in all_so_objs {
    so_argv += [obj]
  }

  so_argv += ["-o", libc_so]

  tasks += [{
    name: libc_so.display(),
    outputs: [libc_so],
    inputs: all_so_objs,
    deps: all_so_deps,
    argv: so_argv,
    cwd: p".",
    env: {},
    depfile: p"",
    stamp: fp"{libc_so}.cmd",
  }]

  make.run_tasks(tasks, make.jobs()?)

  # CRT startup objects — compiled with -DCRT, installed as .o files.
  # Non-PIE: crt1, crti, crtn (compile_c, no -fPIC).
  # PIE:     Scrt1, rcrt1 (compile_lo adds -fPIC/-DPIC for PIE executables).
  let crt_cflags = cflags.push("-DCRT")
  var crt_tasks = []
  var crt_outs: List[Path] = []

  for src_name in ["crt1", "crti", "crtn"] {
    let src = fp"crt/{src_name}.c"
    let out = fp"obj/{src_name}.o"
    let task = make.compile_c_task(cc, triple, crt_cflags, [], includes, src, out)
    crt_tasks += [{...task, stamp: p""}]
    crt_outs += [out]
  }

  for src_name in ["Scrt1", "rcrt1"] {
    let src = fp"crt/{src_name}.c"
    let out = fp"obj/{src_name}.o"
    let task = make.compile_lo_task(cc, triple, crt_cflags, [], includes, src, out)
    crt_tasks += [{...task, stamp: p""}]
    crt_outs += [out]
  }

  make.run_tasks(crt_tasks, make.jobs()?)

  for out in crt_outs {
    fs.install(out, fp"{dest}/usr/lib/{out.name()}", 0o644, parents: true, overwrite: true)
  }

  # Install shared library and static archive.
  fs.install(libc_so, fp"{dest}/usr/lib/libc.so", 0o755, parents: true, overwrite: true)
  fs.install(libc_a, fp"{dest}/usr/lib/libc.a", 0o644, parents: true, overwrite: true)

  for builtin in builtins {
    fs.install(builtin, fp"{dest}/usr/lib/{builtin.name()}", 0o644, parents: true, overwrite: true)
  }

  let packaged_builtin = fp"llvm-toolchain-target/usr/lib/llvm23/lib/clang/23/lib/linux/libclang_rt.builtins-{arch}.a"

  if fs.exists(packaged_builtin)? {
    fs.install(packaged_builtin, fp"{dest}/usr/lib/{packaged_builtin.name()}", 0o644, parents: true, overwrite: true)
  }

  # These libraries are folded into libc on musl, but compiler drivers and
  # upstream build systems still commonly link with their conventional names.
  # Keep the aliases as relative symlinks so they do not duplicate libc in the
  # installed root or package archive.
  for lib in ["m", "dl", "rt", "crypt", "pthread"] {
    fs.symlink(p"libc.so", fp"{dest}/usr/lib/lib{lib}.so")
    fs.symlink(p"libc.a", fp"{dest}/usr/lib/lib{lib}.a")
  }

  # Clang's musl driver links libssp_nonshared by default. Keep the archive
  # empty: stack protector support is disabled in the toolchain wrapper.
  let ar = process.which("ar")?
  let libssp = p"obj/libssp_nonshared.a"
  run $ar "rcs" $libssp ?
  fs.install(libssp, fp"{dest}/usr/lib/libssp_nonshared.a", 0o644, parents: true, overwrite: true)

  # Install public headers from include/ (.h.in templates are excluded by the
  # .ext filter; the generated bits/ headers are picked up by recursive walk).
  let include_root = path.absolute(p"include")?

  for e in fs.files(p"include")? |> where .ext == "h" {
    let rel_path = e.path.relative_to(include_root)
    fs.install(e.path, fp"{dest}/usr/include/{rel_path}", 0o644, parents: true, overwrite: true)
  }

  for bits_dir in [p"arch/generic/bits", fp"arch/{arch}/bits"] {
    let bits_root = path.absolute(bits_dir)?

    for e in fs.files(bits_dir)? |> where .ext == "h" {
      let rel_path = e.path.relative_to(bits_root)
      fs.install(e.path, fp"{dest}/usr/include/bits/{rel_path}", 0o644, parents: true, overwrite: true)
    }
  }

  # musl installs ld-musl-*.so.1 as a hard link to libc.so. Use a relative
  # symlink in the package so the alias does not duplicate the libc payload.
  # Ship the loader under /usr/lib; baselayout provides /lib -> usr/lib
  # for binaries whose ELF interpreter is /lib/ld-musl-*.so.1.
  var ldso = ""

  if arch == "aarch64" {
    ldso = "ld-musl-aarch64.so.1"
  } else if arch == "x86_64" {
    ldso = "ld-musl-x86_64.so.1"
  }

  if ldso != "" {
    fs.symlink(p"libc.so", fp"{dest}/usr/lib/{ldso}")
    fs.mkdir(fp"{dest}/usr/bin")
    fs.remove(fp"{dest}/usr/bin/ldd", missing_ok: true)

    fs.write(
      fp"{dest}/usr/bin/ldd",
      f"""#!/bin/xsh
proc main(...argv: List[Str]) [process, error] {{{{
  unix.exec(process.command_argv("/usr/lib/{ldso}", ["/usr/lib/{ldso}", "--list"].extend(argv)))?
}}}}

main(@args)?
""",
    )

    fs.chmod(fp"{dest}/usr/bin/ldd", 0o755)
  }
}
