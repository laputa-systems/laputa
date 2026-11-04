##! Shared HarfBuzz package.
use pm.env as pm_env
use pm.make

## Package name.
export const name = "harfbuzz"
## Package kind.
export const package_kind = "payload"
## Upstream version.
export const ver = "15.0.0"
## Package revision.
export const rel = "1"
## Runtime dependencies.
export const deps = ["musl", "freetype"]
## Build dependencies.
export const mkdeps_host = ["llvm-toolchain", "cmake", "samurai", "pkgconf"]
## Verified source archive.
export const upstream_sources = [
  {
    source: p"https://github.com/harfbuzz/harfbuzz/releases/download/VERSION/harfbuzz-VERSION.tar.xz",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df"}],
  },
]
## Installed files.
export const filetree = [
  {path: p"usr/include/harfbuzz", kind: "tree"},
  {path: p"usr/lib/cmake/harfbuzz", kind: "tree"},
  {path: p"usr/lib/libharfbuzz.so", kind: "symlink"},
  {path: p"usr/lib/libharfbuzz.so.0", kind: "symlink"},
  {path: p"usr/lib/libharfbuzz.so.0.61500.0", kind: "binary"},
  {path: p"usr/lib/pkgconfig/harfbuzz.pc", kind: "file"},
]
## Build the shared library.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake_file = p"CMakeLists.txt"
  let text = cmake_file.read_text()?
  cmake_file.write(text.replace(
    "target_link_libraries(harfbuzz ",
    with: "set_target_properties(harfbuzz PROPERTIES VERSION 0.61500.0 SOVERSION 0)\ntarget_link_libraries(harfbuzz ",
  ))
  let cmake = process.which("cmake")?
  let samu = process.which("samu")?
  let jobs = make.jobs()?
  run $cmake "-S" "." "-B" "build" "-G" "Ninja" "-DCMAKE_BUILD_TYPE=Release" \
    pm_env.cmake_install_prefix_arg() pm_env.cmake_install_libdir_arg() \
    "-DBUILD_SHARED_LIBS=ON" "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON" \
    "-DCMAKE_CXX_FLAGS_RELEASE=-Oz -DNDEBUG -DHB_MINI" "-DHB_HAVE_FREETYPE=ON" \
    "-DHB_BUILD_SUBSET=OFF" "-DHB_BUILD_RASTER=OFF" "-DHB_BUILD_VECTOR=OFF" \
    "-DHB_BUILD_GPU=OFF" "-DHB_BUILD_UTILS=OFF" "-DHB_HAVE_GLIB=OFF" \
    "-DHB_HAVE_CAIRO=OFF" "-DHB_HAVE_ICU=OFF" "-DHB_HAVE_GRAPHITE2=OFF"
  run $samu "-v" "-C" "build" f"-j{jobs}"
  env ({DESTDIR: dest}) {
    cd (p"build") {
      run $cmake "-P" "cmake_install.cmake"
    }
  }?
}
