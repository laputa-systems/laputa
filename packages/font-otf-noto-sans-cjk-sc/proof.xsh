use pm.proof
use pm.util as pm_util

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "font-otf-noto-sans-cjk-sc")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "noto sans cjk sc ok: cross-built"
    return
  }
  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-noto-sans-cjk-sc" {
    fp"{tmp}/proof.c".write(
      """#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>

int main(int argc, char **argv) {
  FT_Library library;
  FT_Face face;
  if (argc != 2 || FT_Init_FreeType(&library)) return 1;
  if (FT_New_Face(library, argv[1], 0, &face)) return 2;
  if (!FT_Get_Char_Index(face, 0x4e2d) || !FT_Get_Char_Index(face, 0x6587) || !FT_Get_Char_Index(face, 0x3042) || !FT_Get_Char_Index(face, 0xd55c)) return 3;
  if (FT_Set_Pixel_Sizes(face, 0, 24) || FT_Load_Char(face, 0x4e2d, FT_LOAD_RENDER)) return 4;
  if (!face->glyph->bitmap.width || !face->glyph->bitmap.rows) return 5;
  hb_font_t *font = hb_ft_font_create_referenced(face);
  hb_buffer_t *buffer = hb_buffer_create();
  hb_buffer_add_utf8(buffer, "日本語한글中文", -1, 0, -1);
  hb_buffer_guess_segment_properties(buffer);
  hb_shape(font, buffer, NULL, 0);
  unsigned int count;
  hb_glyph_info_t *glyphs = hb_buffer_get_glyph_infos(buffer, &count);
  if (count != 7) return 6;
  for (unsigned int i = 0; i < count; i++) if (!glyphs[i].codepoint) return 7;
  hb_buffer_destroy(buffer);
  hb_font_destroy(font);
  FT_Done_Face(face);
  FT_Done_FreeType(library);
  return 0;
}
""",
    )
    let binary = fp"{tmp}/proof"
    run $cc fp"{tmp}/proof.c" f"-I{root}/usr/include/freetype2" f"-I{root}/usr/include/harfbuzz" f"-L{root}/usr/lib" "-lharfbuzz" "-lfreetype" "-o" $binary
    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
      run $binary fp"{root}/usr/share/fonts/OTF/NotoSansCJKsc-Regular.otf"
    }
  }
  print "noto sans cjk sc ok: Han, kana and Hangul shaping and CFF rasterization"
}
