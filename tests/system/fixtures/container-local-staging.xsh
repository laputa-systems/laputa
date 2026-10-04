##! Published-arm64 regression: a case-sensitive target root stays container-local and only its final image crosses /output.
use system.container_output as container_output
use system.image as image

proc main() [fs, process, error] {
  let workspace = /tmp/laputa-container-local-staging
  let output = /output/container-local-staging
  fs.remove(workspace, missing_ok: true)?
  fs.remove(output, missing_ok: true)?
  defer fs.remove(workspace, missing_ok: true)?
  defer fs.remove(output, missing_ok: true)?

  let root = fp"{workspace}/generation"
  let upper = fp"{root}/usr/include/linux/netfilter/xt_CONNMARK.h"
  let lower = fp"{root}/usr/include/linux/netfilter/xt_connmark.h"
  fs.mkdir(upper.parent)?
  fs.write(
    upper,
    """upper header
""",
  )?
  fs.write(
    lower,
    """lower header
""",
  )?

  if fs.read_text(upper)? != """upper header
""" or fs.read_text(lower)? != """lower header
""" {
    return error.fail("container-local generation did not retain both case-distinct Linux headers")
  }

  let staged_rootfs = fp"{workspace}/rootfs.ext4"
  image.image_write_rootfs(root, /src/laputa/packages/laputa-fs/files/mkfs.ext4.xsh, staged_rootfs)?

  if ! fs.exists(staged_rootfs)? or fs.metadata(staged_rootfs)?.size <= 0 {
    return error.fail("container-local image was not produced from the staged generation")
  }

  let final_rootfs = fp"{output}/rootfs.ext4"
  container_output.publish_final_file(staged_rootfs, final_rootfs)?

  if ! fs.exists(final_rootfs)? or fs.exists(fp"{output}/generation")? or fs.exists(fp"{output}/generations")? {
    return error.fail("host output contains staging state instead of only final image artifacts")
  }

  print "container-local-staging-ok"
}

main()?
