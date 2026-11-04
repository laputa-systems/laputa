use pm.proof
use pm.util as pm_util

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "libpng")
  proof.target_elf(root, p"usr/lib/libpng16.so.16", "libpng")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/usr/lib/libpng16.so.16"
  proof.ensure("[libpng16.so.16]" in dynamic, "proof-libpng", "wrong libpng SONAME")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "libpng ok: cross-built"
    return
  }
  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-libpng" {
    fp"{tmp}/proof.c".write(
      """#include <png.h>
#include <string.h>

int main(void) {
  png_image image;
  memset(&image, 0, sizeof image);
  image.version = PNG_IMAGE_VERSION;
  image.width = 1;
  image.height = 1;
  image.format = PNG_FORMAT_RGBA;
  const unsigned char pixel[4] = {12, 34, 56, 78};
  unsigned char encoded[256];
  png_alloc_size_t size = sizeof encoded;
  if (!png_image_write_to_memory(&image, encoded, &size, 0, pixel, 0, NULL)) return 1;
  memset(&image, 0, sizeof image);
  image.version = PNG_IMAGE_VERSION;
  if (!png_image_begin_read_from_memory(&image, encoded, size)) return 2;
  image.format = PNG_FORMAT_RGBA;
  unsigned char decoded[4];
  if (!png_image_finish_read(&image, NULL, decoded, 0, NULL)) return 3;
  return memcmp(pixel, decoded, sizeof pixel) != 0;
}
""",
    )
    let binary = fp"{tmp}/proof"
    run $cc fp"{tmp}/proof.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-lpng16" "-o" $binary
    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
      run $binary
    }
  }
  print "libpng ok: PNG RGBA round trip"
}
