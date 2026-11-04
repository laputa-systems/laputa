##! Package recipe metadata and build operations.
use pm.env as pm_env
use pm.make

## Package recipe export.
export const name = "vulkan-loader"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.4.363.0"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "cmake", "samurai", "pkgconf", "vulkan-headers"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/KhronosGroup/Vulkan-Loader/archive/refs/tags/vulkan-sdk-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "941eff558fc74f248745fb7df367640cf89a8457f216dae498a74ae14b6ba6f7",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {path: p"usr/lib/cmake/VulkanLoader", kind: "tree"},
  {path: p"usr/lib/libvulkan.so", kind: "symlink"},
  {path: p"usr/lib/libvulkan.so.1", kind: "symlink"},
  {path: p"usr/lib/libvulkan.so.1.4.363", kind: "binary"},
  {path: p"usr/lib/pkgconfig/vulkan.pc", kind: "file"},
]

## Wayland is Laputa's only window system; the loader's Wayland WSI needs only
## the Vulkan headers, not libwayland-client.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake = process.which("cmake")?
  let samu = process.which("samu")?
  run $cmake "-S" "." "-B" "build" "-G" "Ninja" "-DCMAKE_BUILD_TYPE=Release" \
    pm_env.cmake_install_prefix_arg() pm_env.cmake_install_libdir_arg() \
    "-DBUILD_WSI_XCB_SUPPORT=OFF" "-DBUILD_WSI_XLIB_SUPPORT=OFF" "-DBUILD_WSI_XLIB_XRANDR_SUPPORT=OFF" \
    "-DBUILD_WSI_WAYLAND_SUPPORT=ON" "-DBUILD_TESTS=OFF"
  run $samu "-C" "build" f"-j{make.jobs()?}"

  env ({
    DESTDIR: dest,
  }) {
    cd (p"build") {
      run $cmake "-P" "cmake_install.cmake"
    }
  }?
}
