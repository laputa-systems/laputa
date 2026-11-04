use pm.proof
use pm.util as pm_util

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "harfbuzz")
  proof.target_elf(root, p"usr/lib/libharfbuzz.so.0", "harfbuzz")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/usr/lib/libharfbuzz.so.0"
  proof.ensure("[libharfbuzz.so.0]" in dynamic, "proof-harfbuzz", "wrong HarfBuzz SONAME")
  proof.ensure("[libfreetype.so.6]" in dynamic, "proof-harfbuzz", "missing FreeType integration")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "harfbuzz ok: cross-built"
    return
  }
  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-harfbuzz" {
    fp"{tmp}/proof.c".write(
      """#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>

static int shape(hb_font_t *font, const char *text, unsigned int expected) {
  hb_buffer_t *buffer = hb_buffer_create();
  hb_buffer_add_utf8(buffer, text, -1, 0, -1);
  hb_buffer_guess_segment_properties(buffer);
  hb_shape(font, buffer, NULL, 0);
  unsigned int count;
  hb_glyph_info_t *glyphs = hb_buffer_get_glyph_infos(buffer, &count);
  int ok = count == expected;
  for (unsigned int i = 0; i < count; i++) if (!glyphs[i].codepoint) ok = 0;
  hb_buffer_destroy(buffer);
  return ok;
}

int main(int argc, char **argv) {
  FT_Library library;
  FT_Face face;
  if (argc != 2 || FT_Init_FreeType(&library)) return 1;
  if (FT_New_Face(library, argv[1], 0, &face)) return 2;
  if (FT_Set_Pixel_Sizes(face, 0, 18)) return 3;
  hb_font_t *font = hb_ft_font_create_referenced(face);
  hb_buffer_t *buffer = hb_buffer_create();
  hb_buffer_add_utf8(buffer, "ABC", -1, 0, -1);
  hb_buffer_guess_segment_properties(buffer);
  hb_shape(font, buffer, NULL, 0);
  unsigned int count;
  hb_glyph_info_t *glyphs = hb_buffer_get_glyph_infos(buffer, &count);
  hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &count);
  if (count != 3 || glyphs[0].codepoint != FT_Get_Char_Index(face, 'A')) return 4;
  if (positions[0].x_advance <= 0) return 5;
  hb_buffer_destroy(buffer);
  if (!shape(font, "ffi", 1)) return 6;
  if (!shape(font, "é", 1)) return 7;
  if (!shape(font, "سلام", 3)) return 8;
  if (!shape(font, "שלום", 4)) return 9;
  hb_font_destroy(font);
  FT_Done_Face(face);
  FT_Done_FreeType(library);
  return 0;
}
""",
    )
    let binary = fp"{tmp}/proof"
    let machine = (system.uname()?).machine
    let loader = fp"{root}/usr/lib/ld-musl-{machine}.so.1"
    let pkg_config = fp"{root}/usr/bin/pkgconf"
    let pc_dir = fp"{root}/usr/lib/pkgconfig".display()
    var flags = ""
    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display(), PKG_CONFIG_LIBDIR: pc_dir, PKG_CONFIG_PATH: pc_dir, PKG_CONFIG_SYSROOT_DIR: root.display()}) {
      flags = run.text $loader $pkg_config "--cflags" "--libs" "harfbuzz" "freetype2"
    }
    proof.ensure(f"{root}/usr/include/harfbuzz" in flags and f"{root}/usr/lib" in flags, "proof-harfbuzz", "pkg-config paths do not use the relocated root")
    let args = flags.trim().split(" ")
    run $cc fp"{tmp}/proof.c" @args "-o" $binary
    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display()}) {
      run $binary fp"{root}/usr/share/fonts/TTF/DejaVuSans.ttf"
    }
  }
  print "harfbuzz ok: FreeType shaping, ligatures, combining marks, Arabic and Hebrew"
}
