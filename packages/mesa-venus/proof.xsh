##! XSH module `proof` package and build operations.
use pm.proof

const venus_library = "libvulkan_virtio.so"
const venus_icd = p"usr/share/vulkan/icd.d/virtio_icd.json"

proc main(root = p"/rootfs") [fs, process, env, error] {
  let library = p"usr/lib/libvulkan_virtio.so"
  proof.target_elf(root, library, "mesa-venus")

  for needed in elf.inspect(fp"{root}/{library}")?.needed {
    proof.ensure(
      ! needed.starts_with("libLLVM") and ! needed.starts_with("libc++") and ! needed.starts_with("libgallium"),
      "proof-mesa-venus",
      f"{library} links {needed}",
    )
  }

  let icd = json.read(fp"{root}/{venus_icd}")?
  let named = json.get(icd, ["ICD", "library_path"], "").require(Str)?
  proof.ensure(named == venus_library, "proof-mesa-venus", f"the Venus ICD names {named}")

  for forbidden in [p"usr/lib/libvulkan_lvp.so", p"usr/share/vulkan/icd.d/lvp_icd.json"] {
    proof.ensure(! fp"{root}/{forbidden}".exists()?, "proof-mesa-venus", f"{forbidden} must not ship in the Venus variant")
  }

  print "mesa-venus ok: only the virtio Vulkan driver ships, with no LLVM or gallium library"
}
