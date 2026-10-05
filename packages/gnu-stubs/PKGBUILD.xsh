##! XSH module `PKGBUILD` package and build operations.
use pm.util as pm_util

## Exported declaration `name`.
export const name = "gnu-stubs"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "23.1.0-rc2"

## Exported declaration `rel`.
export const rel = "29"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"files/.keep",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/lib/crtbeginS.o",
    kind: "binary",
  },
  {
    path: p"usr/lib/crtendS.o",
    kind: "binary",
  },
  {
    path: p"usr/lib/libgcc_s.so",
    kind: "binary",
  },
  {
    path: p"usr/lib/libgcc_s.so.1",
    kind: "symlink",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let build_arch = pm_util.build_arch()?
  let target_arch = pm_util.target_arch()?

  if build_arch != target_arch or (target_arch != "aarch64" and target_arch != "x86_64") {
    fail "gnu-stubs requires a native aarch64 or x86_64 build"
  }

  let laputa_root = fp"{e"LAPUTA_ROOT" ?? ""}"
  let bootstrap_llvm = e"XSH_PM_BOOTSTRAP_LLVM_ROOT" ?? ""
  let llvm_root = if bootstrap_llvm == "" { fp"{laputa_root}/usr/lib/llvm23" } else { fp"{bootstrap_llvm}" }
  let clang = fp"{llvm_root}/bin/clang"
  let lld = fp"{llvm_root}/bin/ld.lld"
  let llvm_ar = fp"{llvm_root}/bin/llvm-ar"
  let llvm_objcopy = fp"{llvm_root}/bin/llvm-objcopy"
  let libunwind = fp"{llvm_root}/lib/libunwind.a"
  let builtins = fp"{llvm_root}/lib/clang/23/lib/linux/libclang_rt.builtins-{target_arch}.a"

  if ! clang.exists() or ! lld.exists() or ! llvm_ar.exists() or ! llvm_objcopy.exists() {
    fail f"gnu-stubs bootstrap LLVM tools are missing from {llvm_root}"
  }

  # Rust's musl target hardcodes -lgcc_s, and the prebuilt cargo binary
  # dynamically links libgcc_s.so.1 for unwinding. The prebuilt LLVM tree
  # does not ship crtbeginS.o, crtendS.o, or libgcc_s.so.
  #
  # crtbeginS.o / crtendS.o: empty object files. The linker accepts them
  # without symbols; they exist only to satisfy Cargo's link line.
  #
  # libgcc_s.so / libgcc_s.so.1: built from libunwind.a and the compiler-rt
  # objects that provide the helpers required by the dynamically loaded
  # rust-lld. Compiler-rt marks those helpers hidden, so make only these
  # required symbols default-visible before linking the shared object.
  let stub_src = fp"{dest}/.stub.c"
  let builtins_dir = fp"{dest}/.builtins"
  let visibility_map = fp"{dest}/.libgcc.visibility"
  let export_map = fp"{dest}/.libgcc.exports"
  let libdir = fp"{dest}/usr/lib"
  let libgcc = fp"{libdir}/libgcc_s.so"
  let comparetf2 = fp"{builtins_dir}/comparetf2.c.o"
  let divtf3 = fp"{builtins_dir}/divtf3.c.o"
  let extendsftf2 = fp"{builtins_dir}/extendsftf2.c.o"
  let floatsitf = fp"{builtins_dir}/floatsitf.c.o"
  let floatunditf = fp"{builtins_dir}/floatunditf.c.o"
  let multf3 = fp"{builtins_dir}/multf3.c.o"
  let trunctfdf2 = fp"{builtins_dir}/trunctfdf2.c.o"
  let clear_cache = fp"{builtins_dir}/clear_cache.c.o"
  stub_src.write("")
  visibility_map.write(
    """__floatunditf
__divtf3
__clear_cache
__unordtf2
__extendsftf2
__trunctfdf2
__getf2
__multf3
__letf2
__floatsitf
__gttf2
""",
  )
  export_map.write(
    """{
  global:
    *;
};
""",
  )
  libdir.parent.mkdir()
  libdir.mkdir()
  builtins_dir.mkdir()

  env ({
    LD_LIBRARY_PATH: f"{llvm_root}/lib:{e"LD_LIBRARY_PATH" ?? ""}",
  }) {
    run $clang "-target" f"{target_arch}-linux-musl" "-c" $stub_src "-o" fp"{libdir}/crtbeginS.o" ?
    run $clang "-target" f"{target_arch}-linux-musl" "-c" $stub_src "-o" fp"{libdir}/crtendS.o" ?
    cd builtins_dir {
      run $llvm_ar "x" $builtins "comparetf2.c.o" "divtf3.c.o" "extendsftf2.c.o" "floatsitf.c.o" "floatunditf.c.o" "multf3.c.o" "trunctfdf2.c.o" "clear_cache.c.o" ?
    }
    for object in [
      comparetf2,
      divtf3,
      extendsftf2,
      floatsitf,
      floatunditf,
      multf3,
      trunctfdf2,
      clear_cache,
    ] {
      let visible = fp"{object}.visible"
      run $llvm_objcopy f"--set-symbols-visibility={visibility_map}=default" $object $visible ?
      visible.rename(object, overwrite: true)
    }

    stub_src.remove(missing_ok: false)
    run $lld "-shared" "-o" $libgcc "-L" fp"{laputa_root}/usr/lib" "-ldl" "-lpthread" f"--version-script={export_map}" "--no-gc-sections" "-u" "__floatunditf" "-u" "__divtf3" "-u" "__clear_cache" "-u" "__unordtf2" "-u" "__extendsftf2" "-u" "__trunctfdf2" "-u" "__getf2" "-u" "__multf3" "-u" "__letf2" "-u" "__floatsitf" "-u" "__gttf2" "--whole-archive" $libunwind "--no-whole-archive" $comparetf2 $divtf3 $extendsftf2 $floatsitf $floatunditf $multf3 $trunctfdf2 $clear_cache ?
  }

  builtins_dir.remove(missing_ok: false)
  visibility_map.remove(missing_ok: false)
  export_map.remove(missing_ok: false)
  fs.symlink(p"libgcc_s.so", fp"{libdir}/libgcc_s.so.1")
}
