##! Shared FreeType package.
use pm.env as pm_env
use pm.make

## Package name.
export const name = "freetype"
## Package kind.
export const package_kind = "payload"
## Upstream version.
export const ver = "2.15.0"
## Package revision.
export const rel = "3"
## Runtime dependencies.
export const deps = ["musl", "zlib", "libpng"]
## Build dependencies.
export const mkdeps_host = ["llvm-toolchain", "cmake", "samurai"]
## Verified source archive.
export const upstream_sources = [
  {
    source: p"https://download.savannah.gnu.org/releases/freetype/freetype-VERSION.tar.xz",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5"}],
  },
]
## Installed files.
export const filetree = [
  {path: p"usr/include/freetype2", kind: "tree"},
  {path: p"usr/lib/cmake/freetype", kind: "tree"},
  {path: p"usr/lib/libfreetype.so", kind: "symlink"},
  {path: p"usr/lib/libfreetype.so.6", kind: "symlink"},
  {path: p"usr/lib/libfreetype.so.6.20.7", kind: "binary"},
  {path: p"usr/lib/pkgconfig/freetype2.pc", kind: "file"},
]
## Build the shared library.
export proc build(dest: Path) [fs, process, env, error] {
  let modules = p"include/freetype/config/ftmodule.h"
  let text = modules.read_text()?
  modules.write(text
    .replace("FT_USE_MODULE( FT_Driver_ClassRec, t1_driver_class )\n", with: "")
    .replace("FT_USE_MODULE( FT_Driver_ClassRec, t1cid_driver_class )\n", with: "")
    .replace("FT_USE_MODULE( FT_Driver_ClassRec, pfr_driver_class )\n", with: "")
    .replace("FT_USE_MODULE( FT_Driver_ClassRec, t42_driver_class )\n", with: "")
    .replace("FT_USE_MODULE( FT_Driver_ClassRec, winfnt_driver_class )\n", with: "")
    )
  let cmake = process.which("cmake")?
  let samu = process.which("samu")?
  let jobs = make.jobs()?
  run $cmake "-S" "." "-B" "build" "-G" "Ninja" "-DCMAKE_BUILD_TYPE=Release" \
    pm_env.cmake_install_prefix_arg() pm_env.cmake_install_libdir_arg() \
    "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON" \
    "-DBUILD_SHARED_LIBS=ON" "-DFT_REQUIRE_ZLIB=ON" "-DFT_REQUIRE_PNG=ON" \
    "-DFT_DISABLE_HARFBUZZ=ON" "-DFT_DISABLE_BZIP2=ON" "-DFT_DISABLE_BROTLI=ON"
  run $samu "-C" "build" f"-j{jobs}"
  env ({DESTDIR: dest}) {
    cd (p"build") {
      run $cmake "-P" "cmake_install.cmake"
    }
  }?
}
