##! Compose a PM generation and build the ext2 root used by Asterinas.
use hash
use pm.generation as pm_generation
use pm.plan_json as pm_plan_json

const runtime_roots = ["baselayout", "xsh", "laputa-pm", "xinit"]

error AsterinasImageError = Failed

proc main(arch: Str, package_tools_image: Str, profile_overlay_path: Str) [fs, process, error] {
  let plan_path = fp"/src/laputa/.out/world/{arch}/plan.json"
  let store = p"/artifacts"
  let profile_overlay = fp"{profile_overlay_path}"
  let overlay_handle = fs.tempdir()?
  let overlay = fp"{overlay_handle.host_path()?}/overlay"
  let _ = fs.copy_tree(profile_overlay, overlay)?
  let common_boot_setup = p"/src/laputa/guest/asterinas/common/boot-setup.xsh"
  let boot_setup = fp"{overlay}/usr/lib/asterinas/boot-setup.xsh"
  boot_setup.parent.mkdir()
  common_boot_setup.copy(to: boot_setup)
  boot_setup.chmod(0o755)
  let build_plan = pm_plan_json.read(plan_path)?
  let profile = pm_generation.overlay_profile(overlay)?
  let generation_plan = pm_generation.plan_profile(build_plan, runtime_roots, profile)?
  let generation_root = fp"/output/generations/{generation_plan.generation_sha256}"
  run mkdir -p /output/generations

  if generation_root.exists() {
    let receipt = pm_generation.read_generation_receipt(generation_root)?

    if receipt.generation_sha256 != generation_plan.generation_sha256 {
      return Err(AsterinasImageError.Failed("existing Asterinas generation has a different identity"))
    }
  } else {
    let _ = pm_generation.compose(generation_plan, store, generation_root, overlay)?
  }

  run /bin/xsh /src/laputa/pm.xsh -- root inspect $generation_root

  let image = p"/output/laputa-root.ext2"
  let uuid = f"{generation_plan.generation_sha256.byte_slice(0, 8)}-{generation_plan.generation_sha256.byte_slice(8, 4)}-{generation_plan.generation_sha256.byte_slice(12, 4)}-{generation_plan.generation_sha256.byte_slice(16, 4)}-{generation_plan.generation_sha256.byte_slice(20, 12)}"
  let image_key = f"{generation_plan.generation_sha256}\n{package_tools_image}\next2\n512M\nSOURCE_DATE_EPOCH=1 mke2fs -q -F -t ext2 -L LAPUTA -d -U {uuid} -E hash_seed={uuid},lazy_itable_init=0\n"
  let image_key_path = p"/output/laputa-root.ext2.key"
  let image_sha_path = p"/output/laputa-root.ext2.sha256"
  let image_is_cached = image.exists()? and image_key_path.exists()? and image_key_path.read_text()? == image_key

  if image_is_cached {
    let image_sha = hash.sha256(image)?.hex()

    if ! image_sha_path.exists() or image_sha_path.read_text()?.trim() != image_sha {
      return Err(AsterinasImageError.Failed("cached ext2 root image checksum mismatch"))
    }

    run /sbin/e2fsck -fn $image
  } else {
    let stage_handle = fs.tempdir()?
    let rootfs = fp"{stage_handle.host_path()?}/rootfs"
    let _ = fs.copy_tree(generation_root, rootfs)?
    let image_tmp = p"/output/laputa-root.ext2.tmp"
    let _ = image_tmp.remove()?
    run chown -R 0:0 $rootfs
    run truncate -s 512M $image_tmp
    run /usr/bin/env SOURCE_DATE_EPOCH=1 /sbin/mke2fs -q -F -t ext2 -L LAPUTA -d $rootfs -U $uuid -E f"hash_seed={uuid},lazy_itable_init=0" $image_tmp
    run /sbin/e2fsck -fn $image_tmp
    image_tmp.rename(to: image, overwrite: true)
    let image_sha = hash.sha256(image)?.hex()
    image_sha_path.write_atomic(f"{image_sha}\n")
    image_key_path.write_atomic(image_key)
  }

  let ext2_superblock = bytes.read_at(image, 1024, 104)?
  let ext2_magic = bytes.unpack_le(ext2_superblock, 2, 56)?
  let feature_compat = bytes.unpack_le(ext2_superblock, 4, 92)?
  let feature_incompat = bytes.unpack_le(ext2_superblock, 4, 96)?
  let feature_ro_compat = bytes.unpack_le(ext2_superblock, 4, 100)?

  if ext2_magic != 61267 {
    return Err(AsterinasImageError.Failed("root image does not contain an ext2 superblock"))
  }

  if feature_compat % 8 >= 4 {
    return Err(AsterinasImageError.Failed("root ext2 image unexpectedly contains a journal"))
  }

  if feature_incompat != 2 {
    return Err(AsterinasImageError.Failed("root ext2 image has an unsupported incompatible feature"))
  }

  if feature_ro_compat >= 8 {
    return Err(AsterinasImageError.Failed("root ext2 image has an unsupported read-only feature"))
  }

  p"/output/generation.path".write(f"{generation_plan.generation_sha256}\n")

  print f"PM generation: {generation_plan.generation_sha256}"
  print f"Ext2 root: {image}"
}
