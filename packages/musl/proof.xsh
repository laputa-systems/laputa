use pm.target as pm_target
use pm.types

error ScriptError = Failed(kind: Str, message: Str)

proc ensure(condition: Bool, kind: Str, message: Str) {
  if ! condition {
    Err(ScriptError.Failed(kind:, message:))?
  }
}

pure elf_machine_name(target: types.Target) -> Result[Str, Error] {
  match target {
    types.Aarch64LinuxMusl => "AArch64"
    types.X86_64LinuxMusl => "X86-64"
    types.TargetReserved => Err(types.PmError.PackageContract("unsupported ELF target"))
  }
}

proc build_root_path() -> Result[Path] {
  let build_root_value = (e"XSH_PM_BUILD_ROOT" ?? "").trim()
  ensure(build_root_value != "", "proof-musl", "XSH_PM_BUILD_ROOT is required for native-cross proof")
  fp"{build_root_value}"
}

proc cross_cc(default_cc: Path, build_arch: Str, target_arch: Str) -> Result[Path] {
  return default_cc when build_arch == target_arch

  let build_root = build_root_path()?
  fp"{build_root}/usr/lib/llvm23/bin/clang-23"
}

proc compile_hello(
  cc: Path,
  rootfs: Path,
  hello_src: Path,
  hello: Path,
  triple: Str,
  dynlinker: Path,
  build_arch: Str,
  target_arch: Str,
) {
  let include_dir = fp"{rootfs}/usr/include"
  let lib_dir = fp"{rootfs}/usr/lib"

  if build_arch == target_arch {
    run $cc f"--target={triple}" f"--sysroot={rootfs}" "-dynamic" f"-I{include_dir}" f"-L{lib_dir}" \
      f"-Wl,-rpath,{lib_dir}" f"-Wl,-dynamic-linker,{dynlinker}" $hello_src "-o" $hello
    return
  }

  let build_root = build_root_path()?

  env ({
    LD_LIBRARY_PATH: f"{build_root}/usr/lib:{build_root}/usr/lib/llvm23/lib",
    PATH: f"{build_root}/usr/lib/llvm-toolchain/bin:{build_root}/usr/bin:{e"PATH" ?? ""}",
  }) {
    run $cc f"--target={triple}" f"--sysroot={rootfs}" "-fuse-ld=lld" "-nostdlib" fp"{lib_dir}/Scrt1.o" \
      fp"{lib_dir}/crti.o" $hello_src f"-L{lib_dir}" "-lc" fp"{lib_dir}/crtn.o" f"-Wl,-rpath,{lib_dir}" \
      f"-Wl,-dynamic-linker,{dynlinker}" "-o" $hello
  }?
}

proc main(rootfs = /rootfs) [fs, process, env, error] -> Result[Unit, Error] {
  let target = pm_target.recipe_target()?
  let arch = types.pm_target_arch(target)
  let build_arch = types.pm_target_arch(pm_target.build_target()?)
  let triple = f"{arch}-linux-musl"
  let ldso = f"ld-musl-{arch}.so.1"
  let default_cc = process.which("cc")?
  let cc = cross_cc(default_cc, build_arch, arch)?
  let readelf = process.which("readelf")?
  tempdir tmp at fp"{rootfs}/var/tmp/proof-musl" {
    let hello_src = fp"{tmp}/hello.c"

    hello_src.write(
      """#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
/* Linking takes clone's address, so a libc that lost the public clone()
   wrapper (src/linux/clone.c) to an arch file of the same name fails here. */
int (*volatile clone_entry)(int (*)(void *), void *, int, void *, ...) = clone;
int main(void) { puts(clone_entry ? "hello musl" : "no clone"); return 0; }
""",
    )

    let syscalls = fp"{rootfs}/usr/include/bits/syscall.h".read_text()?
    ensure("#define __NR_openat" in syscalls and "#define SYS_openat" in syscalls, "proof-musl", "bits/syscall.h lacks __NR_* or SYS_* names")

    let hello = fp"{tmp}/hello"
    let dynlinker = fp"{rootfs}/usr/lib/{ldso}"
    compile_hello(cc, rootfs, hello_src, hello, triple, dynlinker, build_arch, arch)
    let header = run.text $readelf "-h" $hello
    ensure(elf_machine_name(target)? in header, "proof-musl", f"hello binary is not {arch}")

    if build_arch == arch {
      let out = run.text $dynlinker $hello
      let trimmed = out.trim()

      if trimmed != "hello musl" {
        return Err(ScriptError.Failed(kind: "proof-musl", message: f"unexpected output: {trimmed}"))?
      }

      print "musl ok: "${trimmed}
    } else {
      print "musl ok: cross-built "${arch}
    }
  }
}
