##! XSH module `PKGBUILD` package and build operations.
use pm.make
use pm.util as pm_util

## Exported declaration `name`.
export const name = "iptables"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1.8.13"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "linux-headers"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://www.netfilter.org/projects/iptables/files/iptables-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "1afcd33da9e8f913ace6a2126788162e207e26f5d5e29c6573c0e581ffc58b99",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/bin/ip6tables",
    kind: "symlink",
  },
  {
    path: p"usr/bin/ip6tables-legacy",
    kind: "symlink",
  },
  {
    path: p"usr/bin/ip6tables-legacy-restore",
    kind: "symlink",
  },
  {
    path: p"usr/bin/ip6tables-legacy-save",
    kind: "symlink",
  },
  {
    path: p"usr/bin/ip6tables-restore",
    kind: "symlink",
  },
  {
    path: p"usr/bin/ip6tables-save",
    kind: "symlink",
  },
  {
    path: p"usr/bin/iptables",
    kind: "symlink",
  },
  {
    path: p"usr/bin/iptables-legacy",
    kind: "symlink",
  },
  {
    path: p"usr/bin/iptables-legacy-restore",
    kind: "symlink",
  },
  {
    path: p"usr/bin/iptables-legacy-save",
    kind: "symlink",
  },
  {
    path: p"usr/bin/iptables-restore",
    kind: "symlink",
  },
  {
    path: p"usr/bin/iptables-save",
    kind: "symlink",
  },
  {
    path: p"usr/bin/iptables-xml",
    kind: "symlink",
  },
  {
    path: p"usr/bin/xtables-legacy-multi",
    kind: "binary",
  },
]

const command_links = [
  "iptables",
  "iptables-restore",
  "iptables-save",
  "iptables-legacy",
  "iptables-legacy-restore",
  "iptables-legacy-save",
  "ip6tables",
  "ip6tables-restore",
  "ip6tables-save",
  "ip6tables-legacy",
  "ip6tables-legacy-restore",
  "ip6tables-legacy-save",
  "iptables-xml",
]

const blacklisted_extensions = ["connlabel"]

# configure.ac regular_CPPFLAGS (with large-file support) and regular_CFLAGS,
# including the -D__UAPI_DEF_ETHHDR=0 its musl probe adds. -Wlogical-op is
# left out: it is GCC-only and clang rejects it as an unknown warning.
const regular_flags = [
  "-O2",
  "-Wall",
  "-Waggregate-return",
  "-Wmissing-declarations",
  "-Wmissing-prototypes",
  "-Wredundant-decls",
  "-Wshadow",
  "-Wstrict-prototypes",
  "-Winline",
  "-D__UAPI_DEF_ETHHDR=0",
]

const regular_defs = [
  "-D_LARGEFILE_SOURCE=1",
  "-D_LARGE_FILES",
  "-D_FILE_OFFSET_BITS=64",
  "-D_REENTRANT",
  "-DXTABLES_LIBDIR=\"/usr/lib/xtables\"",
  "-DXTABLES_INTERNAL",
]

proc write_config_h() [fs, error] {
  p"config.h".write(
    f"""#ifndef IPTABLES_CONFIG_H
#define IPTABLES_CONFIG_H
#define HAVE_LINUX_BPF_H 1
#define HAVE_LINUX_MAGIC_H 1
#define PACKAGE_VERSION "{ver}"
#define SIZEOF_STRUCT_IP6_HDR 40
#define XT_LOCK_NAME "/run/xtables.lock"
#endif
""",
  )
}

proc write_xtables_version_h() [fs, error] {
  p"include/xtables-version.h".write(
    """#define XTABLES_VERSION "libxtables.so.12"
#define XTABLES_VERSION_CODE 12
""",
  )
}

proc extension_modules(prefix: Str) -> Result[List[Str]] {
  let modules = collect {
    for entry in fs.children(p"extensions")? |> sort-by .name {
      continue unless entry.kind == "file" and entry.name.starts_with(prefix) and entry.name.ends_with(".c")
      let extension = entry.name.byte_slice(prefix.byte_len(), entry.name.byte_len() - prefix.byte_len() - 2)
      continue when extension in blacklisted_extensions
      yield extension
    }
  }

  modules
}

proc write_initext(file: Path, function_name: Str, hooks: List[Str]) [fs, error] {
  var body = "\n"

  for hook in hooks {
    body += f"extern void {hook}(void);\n"
  }

  body += f"void {function_name}(void);\nvoid {function_name}(void)\n{{\n"

  for hook in hooks {
    body += f" {hook}();\n"
  }

  body += "}\n"
  file.write(body)
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let triple = f"{pm_util.target_arch()?}-linux-musl"
  write_config_h()
  write_xtables_version_h()
  var tasks = []
  var objects = []

  let libiptc = make.compile_c_tasks(
    cc,
    triple,
    regular_flags,
    ["-DHAVE_CONFIG_H", @regular_defs],
    ["-I.", "-Iinclude"],
    p".",
    [p"libiptc/libip4tc.c", p"libiptc/libip6tc.c"],
    p"obj/libiptc",
  )

  let libxtables = make.compile_c_tasks(
    cc,
    triple,
    regular_flags,
    ["-DHAVE_CONFIG_H", @regular_defs, "-DNO_SHARED_LIBS=1"],
    ["-I.", "-Iinclude", "-Iiptables"],
    p".",
    [p"libxtables/xtables.c", p"libxtables/xtoptions.c", p"libxtables/getethertype.c"],
    p"obj/libxtables",
  )

  tasks = tasks.extend(libiptc.tasks).extend(libxtables.tasks)
  objects = [@objects, @libiptc.objects, @libxtables.objects]

  for ext_archive in [
    {prefix: "libxt_", initext: "initext", function_name: "init_extensions"},
    {prefix: "libipt_", initext: "initext4", function_name: "init_extensions4"},
    {prefix: "libip6t_", initext: "initext6", function_name: "init_extensions6"},
  ] {
    let modules = extension_modules(ext_archive.prefix)?
    let hooks = [f"{ext_archive.prefix}{extension}_init" for extension in modules]
    let initext = fp"extensions/{ext_archive.initext}.c"
    write_initext(initext, ext_archive.function_name, hooks)

    let init_task = make.compile_c_task(
      cc,
      triple,
      regular_flags,
      [@regular_defs, f"-D_INIT={ext_archive.initext.replace("init", with: "")}_init"],
      ["-I.", "-Iinclude"],
      initext,
      fp"obj/extensions/{ext_archive.initext}.o",
    )

    tasks += [init_task]
    objects += [init_task.outputs[0]]

    for extension in modules {
      let stem = f"{ext_archive.prefix}{extension}"

      let task = make.compile_c_task(
        cc,
        triple,
        regular_flags,
        [@regular_defs, "-DNO_SHARED_LIBS=1", f"-D_INIT={stem}_init"],
        ["-I.", "-Iinclude"],
        fp"extensions/{stem}.c",
        fp"obj/extensions/{stem}.o",
      )

      tasks += [task]
      objects += [task.outputs[0]]
    }
  }

  let multi = make.compile_c_tasks(
    cc,
    triple,
    regular_flags,
    ["-DHAVE_CONFIG_H", @regular_defs, "-DALL_INCLUSIVE", "-DENABLE_IPV4", "-DENABLE_IPV6"],
    ["-I.", "-Iinclude"],
    p".",
    [
      p"iptables/iptables-xml.c",
      p"iptables/xshared.c",
      p"iptables/xtables-legacy-multi.c",
      p"iptables/iptables-restore.c",
      p"iptables/iptables-save.c",
      p"iptables/iptables-standalone.c",
      p"iptables/iptables.c",
      p"iptables/ip6tables-standalone.c",
      p"iptables/ip6tables.c",
    ],
    p"obj/iptables",
  )

  tasks += multi.tasks
  objects += multi.objects
  let multi_out = p"obj/xtables-legacy-multi"

  let link = make.link_executable_task(cc, triple, objects, [], ["-lm"], multi_out, [task.name for task in tasks])
  make.run_tasks(tasks.push(link), make.jobs()?)

  fs.install(multi_out, fp"{dest}/usr/bin/xtables-legacy-multi", 0o755, parents: true, overwrite: true)

  for command in command_links {
    fp"{dest}/usr/bin/{command}".symlink(to: p"xtables-legacy-multi")
  }
}
