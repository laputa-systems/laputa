##! Package recipe metadata and build operations.
use pm.env as pm_env
use pm.make

## Package recipe export.
export const name = "zlib"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.4"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "cmake", "gluon"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://zlib.net/fossils/zlib-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "02dd159783677a749c04adbdd02b55b8a2bcc7e054f51b76b549199a916ad584",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/include/zconf.h",
    kind: "file",
  },
  {
    path: p"usr/include/zlib.h",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/zlib/ZLIB-shared-release.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/zlib/ZLIB-shared.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/zlib/ZLIB-static-release.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/zlib/ZLIB-static.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/zlib/ZLIBConfig.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/cmake/zlib/ZLIBConfigVersion.cmake",
    kind: "file",
  },
  {
    path: p"usr/lib/libz.a",
    kind: "file",
  },
  {
    path: p"usr/lib/libz.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libz.so.1",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libz.so.1.4",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/zlib.pc",
    kind: "file",
  },
  {
    path: p"usr/share/doc/zlib/zlib/LICENSE",
    kind: "file",
  },
  {
    path: p"usr/share/doc/zlib/zlib/algorithm.txt",
    kind: "file",
  },
  {
    path: p"usr/share/doc/zlib/zlib/crc-doc.1.0.pdf",
    kind: "file",
  },
  {
    path: p"usr/share/doc/zlib/zlib/rfc1950.txt",
    kind: "file",
  },
  {
    path: p"usr/share/doc/zlib/zlib/rfc1951.txt",
    kind: "file",
  },
  {
    path: p"usr/share/doc/zlib/zlib/rfc1952.txt",
    kind: "file",
  },
  {
    path: p"usr/share/doc/zlib/zlib/txtvsbin.txt",
    kind: "file",
  },
  {
    path: p"usr/share/man/man3/zlib.3",
    kind: "file",
  },
]

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake = process.which("cmake")?
  let ninja = process.which("ninja")?
  let jobs = make.jobs()?
  let jobs_flag = f"-j{jobs}"

  let cmake_args = [
    "-G",
    "Ninja",
    "-B",
    "build",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_SHARED_LIBS=ON",
    "-DZLIB_BUILD_TESTING=OFF",
    pm_env.cmake_install_prefix_arg(),
    pm_env.cmake_install_libdir_arg(),
  ]

  run $cmake ${cmake_args}
  run $ninja "-C" "build" $jobs_flag

  env ({
    DESTDIR: dest,
  }) {
    cd (p"build") {
      run $cmake "-P" "cmake_install.cmake"
    }
  }
}
