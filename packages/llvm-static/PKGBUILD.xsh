##! Static LLVM libraries for embedding an LLVM JIT, built for the target
##! architecture only, under the self-contained prefix /usr/lib/llvm-static.
##! Mesa links them into libgallium and lavapipe, so no LLVM shared library
##! enters a runtime closure. `llvm-config` stays for build-time consumers
##! with a config-tool lookup, such as Mesa's generated-source regeneration.
use pm.make
use pm.target as pm_target
use pm.util as pm_util

## Package name.
export const name = "llvm-static"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Upstream LLVM version; matches llvm-toolchain so one libc++ serves both.
export const ver = "23.1.5"

## Package release revision.
export const rel = "1"

## `llvm-config` links libc; the static archives carry no runtime dependencies.
export const deps = ["musl"]

## Host-side build dependencies.
export const mkdeps_host = ["llvm-toolchain", "cmake", "gluon"]

## Upstream source archives and checksums.
export const upstream_sources = [
  {
    source: p"https://github.com/llvm/llvm-project/releases/download/llvmorg-VERSION/llvm-project-VERSION.src.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "fb50b1eac93ddeb3aa8dab4cfe324dff74f4a9c2bdee6160c9e36188f8d06a6e",
      },
    ],
  },
]

## Installed package file tree.
export const filetree = [
  {
    path: p"usr/lib/llvm-static",
    kind: "tree",
  },
  {
    path: p"usr/lib/llvm-static/bin/llvm-config",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/llvm.pc",
    kind: "file",
  },
]

const llvm_prefix = "/usr/lib/llvm-static"

error LlvmStaticError = Failed(kind: Str, message: Str)

pure llvm_target(arch: Str) -> Result[Str, Error] {
  match arch {
    "x86_64" => Ok("X86"),
    "aarch64" => Ok("AArch64"),
    other => Err(LlvmStaticError.Failed(kind: "llvm-target", message: f"no LLVM target for {other}")),
  }
}

# LLVM's configure requires a Python interpreter even when tests and docs are
# off, where nothing in the library build runs it. Laputa builds carry no
# Python, so the recipe drops the requirement instead of supplying one.
proc patch_python_requirement() {
  let file = p"llvm/CMakeLists.txt"
  let text = file.read_text()?
  let old = r"""find_package(Python3 ${LLVM_MINIMUM_PYTHON_VERSION} REQUIRED
    COMPONENTS Interpreter)"""

  if old not in text {
    return Err(LlvmStaticError.Failed(kind: "llvm-patch", message: "llvm/CMakeLists.txt no longer requires Python3 as this recipe expects"))
  }

  file.write(text.replace(old, with: r"""find_package(Python3 ${LLVM_MINIMUM_PYTHON_VERSION}
    COMPONENTS Interpreter)"""))
}

# muon has no llvm-config dependency method, so consumers find LLVM through
# this file. Static archives let the linker keep only the objects a consumer
# uses; `has_rtti` answers Mesa's RTTI ABI check.
pure llvm_pc(version: Str, libs: Str, system_libs: Str) -> Str {
  f"""prefix={llvm_prefix}
libdir=${{prefix}}/lib
includedir=${{prefix}}/include
has_rtti=NO

Name: LLVM
Description: Static LLVM libraries for embedding a JIT
Version: {version}
Libs: -L${{libdir}} {libs} {system_libs}
Cflags: -I${{includedir}}
"""
}

# LLVM infers its host triple by running config.guess through `sh`, which
# Laputa build roots do not provide; the recipe target names the triple.
proc patch_host_triple(triple: Str) {
  let file = p"llvm/cmake/modules/GetHostTriple.cmake"
  let text = file.read_text()?
  let old = r"""      set(config_guess ${LLVM_MAIN_SRC_DIR}/cmake/config.guess)
      execute_process(COMMAND sh ${config_guess}
        RESULT_VARIABLE TT_RV
        OUTPUT_VARIABLE TT_OUT
        OUTPUT_STRIP_TRAILING_WHITESPACE)
      if( NOT TT_RV EQUAL 0 )
        message(FATAL_ERROR "Failed to execute ${config_guess}")
      endif( NOT TT_RV EQUAL 0 )
      set( value ${TT_OUT} )
"""

  if old not in text {
    return Err(LlvmStaticError.Failed(kind: "llvm-patch", message: "GetHostTriple.cmake no longer runs config.guess as this recipe expects"))
  }

  file.write(text.replace(old, with: f"""      set( value "{triple}" )
"""))
}

## Build and install the static LLVM libraries.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake = process.which("cmake")?
  let ninja = process.which("ninja")?
  let target = llvm_target(pm_util.target_arch()?)?
  let jobs_flag = f"-j{make.jobs()?}"
  patch_python_requirement()
  patch_host_triple(pm_target.rust_triple(pm_target.recipe_target()?)?)
  let cmake_args = [
    "-S",
    "llvm",
    "-B",
    "build",
    "-G",
    "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    f"-DCMAKE_INSTALL_PREFIX={llvm_prefix}",
    "-DCMAKE_INSTALL_LIBDIR=lib",
    f"-DLLVM_TARGETS_TO_BUILD={target}",
    "-DLLVM_ENABLE_PROJECTS=",
    "-DLLVM_ENABLE_RUNTIMES=",
    "-DLLVM_BUILD_LLVM_DYLIB=OFF",
    "-DLLVM_LINK_LLVM_DYLIB=OFF",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DLLVM_ENABLE_PIC=ON",
    "-DLLVM_ENABLE_RTTI=OFF",
    "-DLLVM_ENABLE_ASSERTIONS=OFF",
    "-DLLVM_ENABLE_ZLIB=OFF",
    "-DLLVM_ENABLE_ZSTD=OFF",
    "-DLLVM_ENABLE_LIBXML2=OFF",
    "-DLLVM_ENABLE_LIBEDIT=OFF",
    "-DLLVM_ENABLE_LIBPFM=OFF",
    "-DLLVM_ENABLE_BINDINGS=OFF",
    "-DLLVM_ENABLE_OCAMLDOC=OFF",
    "-DLLVM_INCLUDE_TESTS=OFF",
    "-DLLVM_INCLUDE_BENCHMARKS=OFF",
    "-DLLVM_INCLUDE_EXAMPLES=OFF",
    "-DLLVM_INCLUDE_DOCS=OFF",
    "-DLLVM_INCLUDE_UTILS=OFF",
    "-DLLVM_BUILD_TOOLS=OFF",
    "-DLLVM_BUILD_UTILS=OFF",
    "-DLLVM_TOOL_LTO_BUILD=OFF",
    "-DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF",
    "-DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF",
  ]
  run $cmake @cmake_args
  run $ninja "-C" "build" $jobs_flag "llvm-libraries" "llvm-headers" "llvm-config"

  env ({
    DESTDIR: dest,
  }) {
    run $ninja "-C" "build" "install-llvm-libraries" "install-llvm-headers"
  }

  let llvm_config = fp"build/bin/llvm-config"
  let version = (run.text $llvm_config "--version").trim()
  let libs = (run.text $llvm_config "--link-static" "--libs" "all").trim()
  let system_libs = (run.text $llvm_config "--link-static" "--system-libs").trim()
  fp"{dest}/usr/lib/pkgconfig".mkdir()
  fp"{dest}/usr/lib/pkgconfig/llvm.pc".write(llvm_pc(version, libs, system_libs))

  for extra in [fp"{dest}{llvm_prefix}/bin", fp"{dest}{llvm_prefix}/share", fp"{dest}{llvm_prefix}/lib/cmake"] {
    extra.remove()
  }

  fs.install(llvm_config, fp"{dest}{llvm_prefix}/bin/llvm-config", 0o755, parents: true, overwrite: true)
}
