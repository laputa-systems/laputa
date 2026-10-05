##! Package recipe metadata and build operations.
use pm.env as pm_env
use pm.make

## Package recipe export.
export const name = "utf8proc"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "2.12.0"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "cmake", "samurai"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/JuliaStrings/utf8proc/archive/vVERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "f564011d38b2888d583d510b08e69ffa15aa117155db1b9b49ef1dfe1fa25111",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/include/utf8proc.h",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/utf8proc/utf8proc-config-version.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/utf8proc/utf8proc-config.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/utf8proc/utf8proc-targets-release.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/utf8proc/utf8proc-targets.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/libutf8proc.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libutf8proc.so.3",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libutf8proc.so.3.3.0",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libutf8proc.pc",
    kind: "file",
  },
]

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake = process.which("cmake")?
  let samu = process.which("samu")?
  let jobs_flag = f"-j{make.jobs()?}"

  let cmake_args = [
    "-G",
    "Ninja",
    "-B",
    "build",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_SHARED_LIBS=ON",
    "-DUTF8PROC_INSTALL=ON",
    pm_env.cmake_install_prefix_arg(),
    pm_env.cmake_install_libdir_arg(),
    "-DBUILD_TESTING=OFF",
  ]

  run $cmake ${cmake_args}
  run $samu "-C" "build" $jobs_flag

  env ({
    DESTDIR: dest,
  }) {
    cd build {
      run $cmake "-P" "cmake_install.cmake"
    }
  }?
}
