##! Install the kernel's userspace headers the way `make headers_install` does.
use pm.util as pm_util
use uapi

pure kernel_srcarch(arch: Str) -> Result[Str] {
  return "arm64" when arch == "aarch64"

  return "x86" when arch == "x86_64"

  Err(uapi.UapiError.Failed(kind: "linux-headers-arch", message: f"unsupported linux-headers arch {arch}"))
}

# One generated asm/unistd header: its syscall table, the ABIs it selects,
# and the offset added to each number, as each arch's Kbuild names them
# (arch/x86/entry/syscalls/Makefile, arch/arm64/kernel/Makefile.syscalls).
type SyscallHeader = {name: Str, table: Path, abis: List[Str], offset: Str}

pure syscall_headers(srcarch: Str) -> List[SyscallHeader] {
  if srcarch == "x86" {
    let table_64 = p"arch/x86/entry/syscalls/syscall_64.tbl"
    return [
      {name: "unistd_32.h", table: p"arch/x86/entry/syscalls/syscall_32.tbl", abis: ["i386"], offset: ""},
      {name: "unistd_64.h", table: table_64, abis: ["common", "64"], offset: ""},
      {name: "unistd_x32.h", table: table_64, abis: ["common", "x32"], offset: "__X32_SYSCALL_BIT"},
    ]
  }

  [
    {
      name: "unistd_64.h",
      table: p"arch/arm64/tools/syscall_64.tbl",
      abis: ["common", "64", "renameat", "rlimit", "memfd_secret"],
      offset: "",
    },
  ]
}

# The `NAME += header.h` entries of one Kbuild variable.
proc kbuild_list(file: Path, variable: Str) -> Result[List[Str]] {
  var names: List[Str] = []

  for line in file.read_text()?.lines() {
    let fields = line.fields()
    continue unless fields.len() == 3 and fields[0] == variable and fields[1] == "+="
    names += [fields[2]]
  }

  names
}

# Kbuild's wrapper rule: an asm header the arch must provide (asm-generic's
# mandatory-y, plus the arch's own generic-y) but does not becomes a one-line
# include of the asm-generic version. A header the arch does provide is never
# wrapped; x86's own stat.h, for one, does not match asm-generic's layout.
proc generate_asm_wrappers(srcarch: Str, generated: Path) {
  let arch_uapi = fp"arch/{srcarch}/include/uapi/asm"
  var wanted = kbuild_list(p"include/uapi/asm-generic/Kbuild", "mandatory-y")?
  wanted += kbuild_list(fp"{arch_uapi}/Kbuild", "generic-y")?

  for header in wanted {
    continue when fp"{arch_uapi}/{header}".exists()
    fp"{generated}/{header}".write(f"""#include <asm-generic/{header}>
""")
  }
}

# One asm/unistd header, as scripts/syscallhdr.sh --emit-nr writes it.
proc generate_syscall_header(header: SyscallHeader, generated: Path) {
  let header_guard = "_UAPI_ASM_" + rx"__".replace(rx"[^A-Z0-9_]".replace(header.name.upper(), with: "_"), with: "_")
  var lines = [f"#ifndef {header_guard}", f"#define {header_guard}", ""]
  var last = -1

  for raw in header.table.read_text()?.lines() {
    let fields = raw.split("#")[0].fields()
    continue when fields.len() < 3 or fields[1] not in header.abis
    last = fields[0] as Int
    let nr = if header.offset == "" { f"{last}" } else { f"({header.offset} + {last})" }
    lines += [f"#define __NR_{fields[2]} {nr}"]
  }

  lines += ["", "#ifdef __KERNEL__", f"#define __NR_syscalls {last + 1}", "#endif", "", f"#endif /* {header_guard} */"]
  fp"{generated}/{header.name}".write(f"""{lines.join("\n")}
""")
}

# linux/version.h for this release, as the top-level Makefile writes it.
proc generate_version_header(version: Str, out: Path) {
  let parts = [part as Int for part in version.split(".")]

  guard parts.len() == 3 else {
    return Err(uapi.UapiError.Failed(kind: "linux-headers-version", message: f"kernel version {version} is not MAJOR.MINOR.SUB"))
  }

  out.write(
    f"""#define LINUX_VERSION_CODE {parts[0] * 65536 + parts[1] * 256 + parts[2]}
#define KERNEL_VERSION(a,b,c) (((a) << 16) + ((b) << 8) + ((c) > 255 ? 255 : (c)))
#define LINUX_VERSION_MAJOR {parts[0]}
#define LINUX_VERSION_PATCHLEVEL {parts[1]}
#define LINUX_VERSION_SUBLEVEL {parts[2]}
""",
  )
}

# Like headers_install: every include/uapi directory, the target's arch uapi
# as asm/, and the headers Kbuild generates for them, all through the same
# userspace rewrite. Runs in the unpacked kernel source.
proc main(dest: Path) [fs, env, error] {
  let srcarch = kernel_srcarch(pm_util.target_arch()?)?
  let generated_linux = p"include/generated/uapi/linux"
  let generated_asm = fp"arch/{srcarch}/include/generated/uapi/asm"
  generated_linux.mkdir()
  generated_asm.mkdir()
  generate_version_header(e"XSH_PM_VERSION" ?? "", fp"{generated_linux}/version.h")
  generate_asm_wrappers(srcarch, generated_asm)

  for header in syscall_headers(srcarch) {
    generate_syscall_header(header, generated_asm)
  }

  let include = fp"{dest}/usr/include"

  for entry in fs.children(p"include/uapi")? |> where .kind == "dir" {
    uapi.install_tree(entry.path, fp"{include}/{entry.name}")
  }

  uapi.install_tree(generated_linux, fp"{include}/linux")
  uapi.install_tree(fp"arch/{srcarch}/include/uapi/asm", fp"{include}/asm")
  uapi.install_tree(generated_asm, fp"{include}/asm")

  # include/uapi/Kbuild's no-export-headers: these linux/ headers only make
  # sense on an arch that provides the asm/ header of the same name.
  for header in ["a.out.h", "kvm.h", "kvm_para.h"] {
    if ! fp"arch/{srcarch}/include/uapi/asm/{header}".exists() and ! fp"{generated_asm}/{header}".exists() {
      fp"{include}/linux/{header}".remove(missing_ok: true)
    }
  }
}

main(@args)
