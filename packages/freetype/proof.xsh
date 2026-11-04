use pm.proof
use pm.util as pm_util

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "freetype")
  proof.target_elf(root, p"usr/lib/libfreetype.so.6", "freetype")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/usr/lib/libfreetype.so.6"
  proof.ensure("[libfreetype.so.6]" in dynamic, "proof-freetype", "wrong FreeType SONAME")
  proof.ensure("[libpng16.so.16]" in dynamic, "proof-freetype", "missing PNG support")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "freetype ok: cross-built"
    return
  }
  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-freetype" {
    fp"{tmp}/proof.c".write(
      """#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MODULE_H

int main(int argc, char **argv) {
  FT_Library library;
  FT_Face face;
  if (argc != 2 || FT_Init_FreeType(&library)) return 1;
  if (!FT_Get_Module(library, "truetype") || !FT_Get_Module(library, "cff")) return 2;
  if (!FT_Get_Module(library, "pcf") || !FT_Get_Module(library, "bdf") || FT_Get_Module(library, "type1")) return 3;
  if (FT_New_Face(library, argv[1], 0, &face)) return 4;
  if (FT_Set_Pixel_Sizes(face, 0, 18)) return 5;
  if (FT_Load_Char(face, 'A', FT_LOAD_RENDER)) return 6;
  if (!face->glyph->bitmap.width || !face->glyph->bitmap.rows) return 7;
  FT_Done_Face(face);
  FT_Done_FreeType(library);
  return 0;
}
""",
    )
    let binary = fp"{tmp}/proof"
    run $cc fp"{tmp}/proof.c" f"-I{root}/usr/include/freetype2" f"-L{root}/usr/lib" "-lfreetype" "-o" $binary
    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
      run $binary fp"{root}/usr/share/fonts/TTF/Hack-Regular.ttf"
    }
  }
  print "freetype ok: module selection and glyph rasterization"
}
