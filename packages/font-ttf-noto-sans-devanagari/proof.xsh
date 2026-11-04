use pm.proof
use pm.util as pm_util

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "font-ttf-noto-sans-devanagari")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "font-ttf-noto-sans-devanagari ok: cross-built"
    return
  }
  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-font-ttf-noto-sans-devanagari" {
    fp"{tmp}/proof.c".write(
      """#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MULTIPLE_MASTERS_H
#include <hb.h>
#include <hb-ft.h>

int main(int argc, char **argv) {
  FT_Library library;
  FT_Face face;
  if (argc != 2 || FT_Init_FreeType(&library)) return 1;
  if (FT_New_Face(library, argv[1], 0, &face)) return 2;
  if (!FT_Get_Char_Index(face, 0x0915) || !FT_Get_Char_Index(face, 0x093f)) return 3;
  FT_MM_Var *axes;
  if (FT_Get_MM_Var(face, &axes) || !axes->num_axis) return 8;
  FT_Fixed coordinate = axes->axis[0].maximum;
  if (FT_Set_Var_Design_Coordinates(face, 1, &coordinate)) return 9;
  FT_Done_MM_Var(library, axes);
  if (FT_Set_Pixel_Sizes(face, 0, 24)) return 4;
  hb_font_t *font = hb_ft_font_create_referenced(face);
  hb_buffer_t *buffer = hb_buffer_create();
  hb_buffer_add_utf8(buffer, "कि", -1, 0, -1);
  hb_buffer_guess_segment_properties(buffer);
  hb_shape(font, buffer, NULL, 0);
  unsigned int count;
  hb_glyph_info_t *glyphs = hb_buffer_get_glyph_infos(buffer, &count);
  if (count != 2 || glyphs[0].codepoint == FT_Get_Char_Index(face, 0x0915)) return 5;
  if (glyphs[0].cluster != 0 || glyphs[1].cluster != 0) return 7;
  for (unsigned int i = 0; i < count; i++) if (!glyphs[i].codepoint) return 6;
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
      run $binary fp"{root}/usr/share/fonts/TTF/NotoSansDevanagari.ttf"
    }
  }
  print "font-ttf-noto-sans-devanagari ok: variable axis and pre-base vowel reordering"
}
