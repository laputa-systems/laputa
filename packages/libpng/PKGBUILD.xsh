##! Shared PNG library package.
use pm.env as pm_env
use pm.make

## Package declaration.
export const name = "libpng"
## Package declaration.
export const package_kind = "payload"
## Package declaration.
export const ver = "1.6.50"
## Package declaration.
export const rel = "1"
## Package declaration.
export const deps = ["musl", "zlib"]
## Package declaration.
export const mkdeps_host = ["llvm-toolchain", "cmake", "samurai"]
## Package declaration.
export const upstream_sources = [
  {
    source: p"https://download.sourceforge.net/libpng/libpng-VERSION.tar.xz",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "4df396518620a7aa3651443e87d1b2862e4e88cad135a8b93423e01706232307"}],
  },
]
## Package declaration.
export const filetree = [
  {path: p"usr/include/libpng16", kind: "tree"},
  {path: p"usr/include/png.h", kind: "file"},
  {path: p"usr/include/pngconf.h", kind: "file"},
  {path: p"usr/include/pnglibconf.h", kind: "file"},
  {path: p"usr/lib/cmake/PNG", kind: "tree"},
  {path: p"usr/lib/libpng", kind: "tree"},
  {path: p"usr/lib/libpng.so", kind: "symlink"},
  {path: p"usr/lib/libpng16.so", kind: "symlink"},
  {path: p"usr/lib/libpng16.so.16", kind: "symlink"},
  {path: p"usr/lib/libpng16.so.16.50.0", kind: "binary"},
  {path: p"usr/lib/pkgconfig/libpng.pc", kind: "symlink"},
  {path: p"usr/lib/pkgconfig/libpng16.pc", kind: "file"},
  {path: p"usr/share/man/man3/libpng.3", kind: "file"},
  {path: p"usr/share/man/man3/libpngpf.3", kind: "file"},
  {path: p"usr/share/man/man5/png.5", kind: "file"},
]

## Build the shared library.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake = process.which("cmake")?
  let samu = process.which("samu")?
  let jobs = make.jobs()?
  run $cmake "-S" "." "-B" "build" "-G" "Ninja" "-DCMAKE_BUILD_TYPE=Release" \
    pm_env.cmake_install_prefix_arg() pm_env.cmake_install_libdir_arg() \
    "-DPNG_SHARED=ON" "-DPNG_STATIC=OFF" "-DPNG_TESTS=OFF" "-DPNG_TOOLS=OFF"
  run $samu "-C" "build" f"-j{jobs}"
  env ({DESTDIR: dest}) {
    cd (p"build") {
      run $cmake "-P" "cmake_install.cmake"
    }
  }?
  fp"{dest}/usr/bin/libpng-config".remove()
  fp"{dest}/usr/bin/libpng16-config".remove()
}
