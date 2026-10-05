use pm.util as pm_util

error ProofError = Failed(kind: Str, message: Str)

proc ensure(condition: Bool, kind: Str, message: Str) {
  if ! condition {
    Err(ProofError.Failed(kind:, message:))?
  }
}

pure elf_machine_name(arch: Str) -> Str {
  return "AArch64" when arch == "aarch64"

  return "X86-64" when arch == "x86_64"

  arch
}

proc build_root_path() -> Result[Path] {
  let build_root_value = (e"XSH_PM_BUILD_ROOT" ?? "").trim()
  ensure(build_root_value != "", "proof-llvm-toolchain", "XSH_PM_BUILD_ROOT is required for native-cross proof")
  fp"{build_root_value}"
}

proc proof_readelf_path(root: Path) -> Result[Path] {
  let target_readelf = fp"{root}/usr/bin/readelf"

  return target_readelf when target_readelf.exists()

  let build_root = build_root_path()?
  fp"{build_root}/usr/bin/readelf"
}

proc ensure_file(path_value: Path, label: Str) {
  ensure(path_value.exists()?, "proof-llvm-toolchain", f"missing {label}: {path_value}")
}

proc ensure_executable(path_value: Path, label: Str) {
  ensure_file(path_value, label)
  let mode = path_value.metadata()?.mode % 4096

  ensure(
    mode in [0o555, 0o755, 0o775, 0o777],
    "proof-llvm-toolchain",
    f"{label} is not executable: {path_value} mode={mode}",
  )
}

proc ensure_xsh_wrapper(path_value: Path, label: Str) {
  ensure_file(path_value, label)
  let text = path_value.read_text()?
  ensure(text.starts_with("#!/bin/xsh"), "proof-llvm-toolchain", f"{label} is not an XSH wrapper")
  ensure(! ("libgcc" in text), "proof-llvm-toolchain", f"{label} mentions libgcc")
  ensure(! ("libstdc++" in text), "proof-llvm-toolchain", f"{label} mentions libstdc++")
}

proc prove_tool_linkage(readelf: Path, tool: Path) {
  ensure_executable(tool, tool.name)
  let program_headers = run.text $readelf "-l" $tool
  ensure(! ("ld-linux" in program_headers), "proof-llvm-toolchain", f"{tool} uses a glibc interpreter")

  if "INTERP" in program_headers {
    ensure("ld-musl" in program_headers, "proof-llvm-toolchain", f"{tool} does not use a musl interpreter")
  }

  let dynamic = run.text $readelf "-d" $tool
  ensure(! ("libunwind.so" in dynamic), "proof-llvm-toolchain", f"{tool} needs libunwind.so")
  ensure(! ("libgcc" in dynamic), "proof-llvm-toolchain", f"{tool} needs libgcc")
  ensure(! ("libstdc++" in dynamic), "proof-llvm-toolchain", f"{tool} needs libstdc++")
}

proc prove_public_surface(root: Path, arch: Str) {
  let readelf = proof_readelf_path(root)?
  let bin = fp"{root}/usr/lib/llvm23/bin"

  for wrapper in [
    "cc",
    "clang",
    "c++",
    "clang++",
    "ld",
    "ld.lld",
    "ar",
    "ranlib",
    "nm",
    "objcopy",
    "objdump",
    "readelf",
    "strip",
    "llvm-ar",
    "llvm-ranlib",
    "llvm-nm",
    "llvm-objcopy",
    "llvm-objdump",
    "llvm-readelf",
    "llvm-strip",
  ] {
    ensure_xsh_wrapper(fp"{root}/usr/bin/{wrapper}", wrapper)
  }

  for tool in [
    "clang",
    "clang++",
    "ld.lld",
    "llvm-ar",
    "llvm-ranlib",
    "llvm-nm",
    "llvm-objcopy",
    "llvm-objdump",
    "llvm-readelf",
    "llvm-strip",
  ] {
    prove_tool_linkage(readelf, fp"{bin}/{tool}")
  }

  ensure_file(fp"{root}/usr/lib/llvm23/lib/clang/23/include/stddef.h", "Clang resource headers")
  ensure_file(fp"{root}/usr/lib/llvm23/lib/clang/23/lib/linux/libclang_rt.builtins-{arch}.a", "compiler-rt builtins")
}

proc prove_default_compile(root: Path, arch: Str) [fs, process, env, error] {
  let machine = elf_machine_name(arch)
  let cc = process.which("cc")?
  let readelf = process.which("llvm-readelf")?
  tempdir tmp at fp"{root}/var/tmp/proof-llvm-toolchain-default" {

    fp"{tmp}/default-target.c".write(
      """int laputa_default_target(void) {
  return 9;
}
""",
    )

    let object = fp"{tmp}/default-target.o"
    run $cc "-target" f"{arch}-linux-musl" "-O2" "-c" fp"{tmp}/default-target.c" "-o" $object
    let header = run.text $readelf "-h" $object
    ensure(machine in header, "proof-llvm-toolchain", f"cc wrapper did not produce a {arch} object")
  }
}

proc prove_native_link(root: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let readelf = process.which("llvm-readelf")?
  tempdir tmp at fp"{root}/var/tmp/proof-llvm-toolchain-native" {

    fp"{tmp}/hello.c".write(
      """int main(void) {
  return 0;
}
""",
    )

    let exe = fp"{tmp}/hello"
    run $cc fp"{tmp}/hello.c" "-o" $exe
    run $exe
    let dynamic = run.text $readelf "-d" $exe
    ensure(! ("libunwind" in dynamic), "proof-llvm-toolchain", "native hello links libunwind")
    ensure(! ("libgcc" in dynamic), "proof-llvm-toolchain", "native hello links libgcc")
    ensure(! ("libstdc++" in dynamic), "proof-llvm-toolchain", "native hello links libstdc++")
  }
}

proc prove_native_cxx_link(root: Path) [fs, process, env, error] {
  let cxx = process.which("c++")?
  let readelf = process.which("llvm-readelf")?
  tempdir tmp at fp"{root}/var/tmp/proof-llvm-toolchain-native-cxx" {

    fp"{tmp}/hello.cc".write(
      """#include <string>

int main(void) {
  std::string value = "laputa";
  return value.size() == 6 ? 0 : 1;
}
""",
    )

    let exe = fp"{tmp}/hello-cxx"
    run $cxx fp"{tmp}/hello.cc" "-o" $exe
    run $exe
    let dynamic = run.text $readelf "-d" $exe
    ensure(! ("libunwind" in dynamic), "proof-llvm-toolchain", "native C++ hello links libunwind")
    ensure(! ("libgcc" in dynamic), "proof-llvm-toolchain", "native C++ hello links libgcc")
    ensure(! ("libstdc++" in dynamic), "proof-llvm-toolchain", "native C++ hello links libstdc++")
  }
}

proc prove_x86_64_v3(root: Path) {
  let cc = process.which("cc")?
  let objdump = process.which("llvm-objdump")?
  tempdir tmp at fp"{root}/var/tmp/proof-llvm-toolchain-v3" {

    fp"{tmp}/v3-toy.c".write(
      """#include <immintrin.h>

__attribute__((noinline))
void laputa_v3_toy(const unsigned long long *a, const unsigned long long *b, unsigned long long *out, unsigned long long mask) {
  __m256i av = _mm256_loadu_si256((const __m256i *)a);
  __m256i bv = _mm256_loadu_si256((const __m256i *)b);
  __m256i sum = _mm256_add_epi64(av, bv);
  _mm256_storeu_si256((__m256i *)out, sum);
  out[4] = _pdep_u64(out[0], mask);
}
""",
    )

    let object = fp"{tmp}/v3-toy.o"
    run $cc "-O2" "-c" fp"{tmp}/v3-toy.c" "-o" $object
    let asm = run.text $objdump "-d" "--no-show-raw-insn" $object
    ensure("vpaddq" in asm, "proof-llvm-toolchain", "x86-64-v3 proof did not emit AVX2 vpaddq")
    ensure("pdep" in asm, "proof-llvm-toolchain", "x86-64-v3 proof did not emit BMI2 pdep")
  }
}

proc prove_explicit_aarch64_target(root: Path) {
  let cc = process.which("cc")?
  let readelf = process.which("llvm-readelf")?
  tempdir tmp at fp"{root}/var/tmp/proof-llvm-toolchain-aarch64" {

    fp"{tmp}/aarch64-target-toy.c".write(
      """int laputa_aarch64_target_toy(void) {
  return 42;
}
""",
    )

    let object = fp"{tmp}/aarch64-target-toy.o"
    run $cc "-target" "aarch64-linux-musl" "-O2" "-c" fp"{tmp}/aarch64-target-toy.c" "-o" $object
    let header = run.text $readelf "-h" $object
    ensure("AArch64" in header, "proof-llvm-toolchain", "explicit aarch64 target did not produce an AArch64 object")
  }
}

proc prove_target_tools(root: Path, arch: Str) {
  let readelf = proof_readelf_path(root)?
  let machine = elf_machine_name(arch)
  let cc = fp"{root}/usr/bin/cc"
  let clang = fp"{root}/usr/lib/llvm23/bin/clang"
  let clang_header = run.text $readelf "-h" $clang
  ensure(machine in clang_header, "proof-llvm-toolchain", f"clang is not {arch}")
  let cc_text = cc.read_text()?
  ensure(cc_text.starts_with("#!/bin/xsh"), "proof-llvm-toolchain", "cc wrapper is not an XSH script")
  let tmp = fp"{root}/var/tmp/proof-llvm-toolchain-wrapper"
  tmp.remove()
  tmp.mkdir()
  defer tmp.remove()

  fp"{tmp}/wrapper-target.c".write(
    """int laputa_wrapper_target(void) {
  return 7;
}
""",
  )

  let object = fp"{tmp}/wrapper-target.o"
  run $cc "-target" f"{arch}-linux-musl" "-O2" "-c" fp"{tmp}/wrapper-target.c" "-o" $object
  let object_header = run.text $readelf "-h" $object
  ensure(machine in object_header, "proof-llvm-toolchain", f"cc wrapper did not produce a {arch} object")
}

proc main(root: Path = /rootfs) [fs, process, env, error] {
  let db = fp"{root}/var/lib/xsh-pm/packages/llvm-toolchain/metadata.json"

  if ! db.exists() {
    return Err(ProofError.Failed(kind: "proof-llvm-toolchain", message: f"missing package metadata: {db}"))
  }

  let target_arch = pm_util.target_arch()?
  let build_arch = pm_util.build_arch()?
  prove_public_surface(root, target_arch)
  prove_default_compile(root, target_arch)

  if build_arch == target_arch and target_arch == "x86_64" {
    prove_x86_64_v3(root)
    prove_explicit_aarch64_target(root)
    prove_native_link(root)
    prove_native_cxx_link(root)
  } else if build_arch == target_arch {
    prove_explicit_aarch64_target(root)
    prove_native_link(root)
    prove_native_cxx_link(root)
  } else {
    prove_target_tools(root, target_arch)
  }

  print "llvm-toolchain ok"
}

main(@args)
