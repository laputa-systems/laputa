##! XSH module `proof` package and build operations.
use pm.proof

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "vulkan-headers")
  let header = fp"{root}/usr/include/vulkan/vulkan_core.h".read_text()?
  proof.ensure(
    "#define VK_HEADER_VERSION 363\n" in header,
    "vulkan-header-version",
    "vulkan_core.h does not declare VK_HEADER_VERSION 363",
  )
  proof.ensure(
    fp"{root}/usr/include/vulkan/vulkan_wayland.h".exists()?,
    "vulkan-wayland-header",
    "vulkan_wayland.h is missing",
  )
  let config = fp"{root}/usr/share/cmake/VulkanHeaders/VulkanHeadersConfigVersion.cmake".read_text()?
  proof.ensure(
    "set(PACKAGE_VERSION \"1.4.363\")" in config,
    "vulkan-headers-cmake-version",
    "VulkanHeadersConfigVersion.cmake does not report 1.4.363",
  )
  print "vulkan-headers ok: 1.4.363 headers and CMake package"
}
