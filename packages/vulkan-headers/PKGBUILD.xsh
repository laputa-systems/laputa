##! Package recipe metadata and build operations.
use pm.env as pm_env
## Package recipe export.
export const name = "vulkan-headers"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.4.363.0"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps: List[Str] = []

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "cmake", "gluon"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/vulkan-sdk-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "4a078be12bef21cfebc09d878b77a63cff9d68f899254a0b00d0e37ef73e7f7e",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {path: p"usr/include/vk_video", kind: "tree"},
  {path: p"usr/include/vulkan", kind: "tree"},
  {path: p"usr/share/cmake/VulkanHeaders", kind: "tree"},
  {path: p"usr/share/vulkan/registry", kind: "tree"},
]

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cmake = process.which("cmake")?
  run $cmake "-S" "." "-B" "build" "-G" "Ninja" pm_env.cmake_install_prefix_arg() "-DVULKAN_HEADERS_ENABLE_TESTS=OFF"

  env ({
    DESTDIR: dest,
  }) {
    cd (p"build") {
      run $cmake "-P" "cmake_install.cmake"
    }
  }?
}
