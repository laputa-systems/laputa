use pm.proof
use pm.util as pm_util

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "font-ttf-dejavu-sans")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "dejavu sans ok: cross-built"
    return
  }
  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-dejavu-sans" {
    fp"{tmp}/proof.c".write(
      """#include <ft2build.h>
#include FT_FREETYPE_H

int main(int argc, char **argv) {
  FT_Library library;
  FT_Face face;
  if (argc != 2 || FT_Init_FreeType(&library)) return 1;
  if (FT_New_Face(library, argv[1], 0, &face)) return 2;
  if (!FT_Get_Char_Index(face, 'A') || !FT_Get_Char_Index(face, 0x05d0) || !FT_Get_Char_Index(face, 0x0633)) return 3;
  FT_Done_Face(face);
  FT_Done_FreeType(library);
  return 0;
}
""",
    )
    let binary = fp"{tmp}/proof"
    run $cc fp"{tmp}/proof.c" f"-I{root}/usr/include/freetype2" f"-L{root}/usr/lib" "-lfreetype" "-o" $binary
    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
      run $binary fp"{root}/usr/share/fonts/TTF/DejaVuSans.ttf"
    }
  }
  print "dejavu sans ok: Latin, Hebrew and Arabic glyph coverage"
}
