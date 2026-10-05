##! XSH module `PKGBUILD` package and build operations.
use pm.env as pm_env

## Exported declaration `name`.
export const name = "expat"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "2.8.5"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "cmake", "samurai"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://github.com/libexpat/libexpat/releases/download/R_2_8_5/expat-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "1e727b8933ec51a77a9a9d9afcf8e688bce45d907c13e36ab7393fe36e703182",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/include/expat.h",
    kind: "file",
  },
  {
    path: p"usr/include/expat_config.h",
    kind: "file",
  },
  {
    path: p"usr/include/expat_external.h",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/expat-2.8.5/expat-config-version.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/expat-2.8.5/expat-config.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/expat-2.8.5/expat-release.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/expat-2.8.5/expat.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/libexpat.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libexpat.so.1",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libexpat.so.1.12.5",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/expat.pc",
    kind: "file",
  },
  {
    path: p"usr/share/doc/expat/AUTHORS",
    kind: "file",
  },
  {
    path: p"usr/share/doc/expat/changelog",
    kind: "file",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake = process.which("cmake")?
  let samu = process.which("samu")?
  let jobs_flag = f"-j{cpu.count()}"

  let cmake_args = [
    "-S",
    ".",
    "-B",
    "build",
    "-G",
    "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    pm_env.cmake_install_prefix_arg(),
    pm_env.cmake_install_libdir_arg(),
    "-DEXPAT_BUILD_DOCS=OFF",
    "-DEXPAT_BUILD_EXAMPLES=OFF",
    "-DEXPAT_BUILD_FUZZERS=OFF",
    "-DEXPAT_BUILD_PKGCONFIG=ON",
    "-DEXPAT_BUILD_TESTS=OFF",
    "-DEXPAT_BUILD_TOOLS=OFF",
    "-DEXPAT_SHARED_LIBS=ON",
  ]

  run $cmake ${cmake_args} ?
  run $samu "-C" "build" $jobs_flag ?

  env ({
    DESTDIR: dest,
  }) {
    cd build {
      run $cmake "-P" "cmake_install.cmake" ?
    }
  }?

  fs.remove(fp"{dest}/usr/lib/libexpat.a", missing_ok: true)
}
