##! XSH module `PKGBUILD` package and build operations.
use pm.env as pm_env
use pm.make

## Exported declaration `name`.
export const name = "libpng"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1.6.59"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl", "zlib"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "cmake", "samurai", "zlib"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://download.sourceforge.net/libpng/libpng-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/include/libpng16/png.h",
    kind: "file",
  },
  {
    path: p"usr/include/libpng16/pngconf.h",
    kind: "file",
  },
  {
    path: p"usr/include/libpng16/pnglibconf.h",
    kind: "file",
  },
  {
    path: p"usr/include/png.h",
    kind: "file",
  },
  {
    path: p"usr/include/pngconf.h",
    kind: "file",
  },
  {
    path: p"usr/include/pnglibconf.h",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/PNG/PNGConfig.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/PNG/PNGConfigVersion.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/PNG/PNGTargets-release.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/PNG/PNGTargets.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/libpng.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libpng/libpng16-release.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/libpng/libpng16.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/libpng16.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libpng16.so.16",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libpng16.so.16.59.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libpng.pc",
    kind: "symlink",
  },
  {
    path: p"usr/lib/pkgconfig/libpng16.pc",
    kind: "file",
  },
]

error LibpngError = Patch(message: Str)

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake = process.which("cmake")?
  let samu = process.which("samu")?
  let jobs_flag = f"-j{make.jobs()?}"

  # CMake's legacy post-build symlink command fails under the XSH build root.
  # Install the unversioned development link after CMake installs the library.
  let cmake_lists = p"CMakeLists.txt".read_text()?

  let post_build_symlink = r"""      create_symlink(${libpng_symlink_name} TARGET png_shared)
      install(FILES "$<TARGET_LINKER_FILE_DIR:png_shared>/${libpng_symlink_name}"
              DESTINATION "${CMAKE_INSTALL_LIBDIR}")
"""

  if post_build_symlink not in cmake_lists {
    return Err(LibpngError.Patch("CMakeLists.txt no longer creates libpng.so after the build"))?
  }

  fs.write(p"CMakeLists.txt", cmake_lists.replace(post_build_symlink, ""))?

  # CMake sees the executor architecture rather than the aarch64 compiler
  # target, so PNG_ARM_NEON is not an effective cache option here.  Set the
  # source-level option explicitly: otherwise core objects select NEON helpers
  # which CMake failed to add to the target, leaving unresolved ELF symbols.
  var cmake_args = [
    "-S",
    ".",
    "-B",
    "build",
    "-G",
    "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    pm_env.cmake_install_prefix_arg(),
    pm_env.cmake_install_libdir_arg(),
    "-DPNG_SHARED=ON",
    "-DPNG_STATIC=OFF",
    "-DCMAKE_C_FLAGS=-DPNG_ARM_NEON_OPT=0",
    "-DPNG_TESTS=OFF",
    "-DPNG_TOOLS=OFF",
    "-DPNG_EXECUTABLES=OFF",
  ]

  let target_root = e"LAPUTA_ROOT" ?? "/"

  if target_root != "" and target_root != "/" {
    cmake_args += [f"-DZLIB_ROOT={target_root}/usr"]
    cmake_args += [f"-DZLIB_LIBRARY={target_root}/usr/lib/libz.so"]
    cmake_args += [f"-DZLIB_INCLUDE_DIR={target_root}/usr/include"]
  }

  run $cmake @cmake_args ?
  run $samu "-C" "build" $jobs_flag ?

  env ({
    DESTDIR: dest,
  }) {
    cd build {
      run $cmake "-P" "cmake_install.cmake" ?
    }
  }?

  fs.symlink(p"libpng16.so", fp"{dest}/usr/lib/libpng.so")?
  fs.remove(fp"{dest}/usr/bin", missing_ok: true)?
  fs.remove(fp"{dest}/usr/share/man", missing_ok: true)?
}
