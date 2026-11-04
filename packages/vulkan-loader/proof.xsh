##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

const probe = """#include <stdint.h>
#include <stdio.h>

typedef int32_t VkResult;
VkResult vkEnumerateInstanceVersion(uint32_t *version);
VkResult vkEnumerateInstanceExtensionProperties(const char *layer, uint32_t *count, void *properties);

int main(void) {
  uint32_t version = 0;
  uint32_t extensions = 0;
  if (vkEnumerateInstanceVersion(&version) != 0) {
    return 1;
  }
  if (vkEnumerateInstanceExtensionProperties(NULL, &extensions, NULL) != 0) {
    return 2;
  }
  printf("%u.%u.%u\\n", (version >> 22) & 0x7f, (version >> 12) & 0x3ff, version & 0xfff);
  return 0;
}
"""

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "vulkan-loader")
  proof.target_elf(root, p"usr/lib/libvulkan.so.1.4.363", "vulkan-loader")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "vulkan-loader ok: cross-built"
    return
  }

  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-vulkan-loader" {
    let source = fp"{tmp}/probe.c"
    let binary = fp"{tmp}/probe"
    source.write(probe)
    run $cc $source f"-L{root}/usr/lib" "-lvulkan" "-o" $binary
    let reported = env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
      run.text $binary
    }?
    proof.ensure(reported == "1.4.363\n", "vulkan-loader-version", f"unexpected loader instance version: {reported.trim()}")
  }
  print "vulkan-loader ok: libvulkan.so.1 reports instance version 1.4.363"
}
