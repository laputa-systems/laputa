use pm.proof
use pm.util as pm_util

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "fontconfig")
  proof.target_elf(root, p"usr/lib/libfontconfig.so.1", "fontconfig")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/usr/lib/libfontconfig.so.1"
  proof.ensure("[libfontconfig.so.1]" in dynamic, "proof-fontconfig", "wrong Fontconfig SONAME")
  proof.ensure("[libexpat.so.1]" in dynamic, "proof-fontconfig", "missing Expat backend")
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "fontconfig ok: cross-built"
    return
  }
  let cc = process.which("cc")?
  tempdir tmp at fp"{root}/var/tmp/proof-fontconfig" {
    fp"{tmp}/proof.c".write(
      """#include <fontconfig/fontconfig.h>
#include <string.h>
#include <stdio.h>

static int match(const char *requested, const char *expected, FcChar32 codepoint) {
  FcPattern *pattern = FcPatternCreate();
  if (!pattern || !FcPatternAddString(pattern, FC_FAMILY, (const FcChar8 *)requested)) return 2;
  if (codepoint) {
    FcCharSet *charset = FcCharSetCreate();
    if (!charset || !FcCharSetAddChar(charset, codepoint) || !FcPatternAddCharSet(pattern, FC_CHARSET, charset)) return 6;
    FcCharSetDestroy(charset);
  }
  if (!FcConfigSubstitute(NULL, pattern, FcMatchPattern)) return 3;
  FcDefaultSubstitute(pattern);
  FcResult result;
  FcPattern *match = FcFontMatch(NULL, pattern, &result);
  FcChar8 *family;
  if (!match || FcPatternGetString(match, FC_FAMILY, 0, &family) != FcResultMatch) return 4;
  int ok = strcmp((const char *)family, expected) == 0;
  if (!ok) fprintf(stderr, "%s matched %s, expected %s", requested, family, expected);
  FcPatternDestroy(match);
  FcPatternDestroy(pattern);
  return !ok;
}

static int available(FcChar32 codepoint, const char *expected, int color) {
  FcPattern *pattern = FcPatternCreate();
  FcCharSet *charset = FcCharSetCreate();
  if (!pattern || !charset || !FcCharSetAddChar(charset, codepoint) ||
      !FcPatternAddCharSet(pattern, FC_CHARSET, charset) ||
      !FcPatternAddString(pattern, FC_FAMILY, (const FcChar8 *)"monospace")) return 1;
  FcCharSetDestroy(charset);
  if (!FcConfigSubstitute(NULL, pattern, FcMatchPattern)) return 1;
  FcDefaultSubstitute(pattern);
  FcResult result;
  FcFontSet *set = FcFontSort(NULL, pattern, FcFalse, NULL, &result);
  FcCharSet *first_coverage;
  if (!set || !set->nfont || FcPatternGetCharSet(set->fonts[0], FC_CHARSET, 0, &first_coverage) != FcResultMatch ||
      !FcCharSetHasChar(first_coverage, codepoint)) return 1;
  int found = 0;
  if (set) for (int i = 0; i < set->nfont; i++) {
    FcChar8 *family;
    FcCharSet *coverage;
    FcBool is_color = FcFalse;
    if (FcPatternGetString(set->fonts[i], FC_FAMILY, 0, &family) != FcResultMatch ||
        FcPatternGetCharSet(set->fonts[i], FC_CHARSET, 0, &coverage) != FcResultMatch) continue;
    FcPatternGetBool(set->fonts[i], FC_COLOR, 0, &is_color);
    if (!strcmp((const char *)family, expected) && FcCharSetHasChar(coverage, codepoint) && (!color || is_color)) found = 1;
  }
  if (!found) fprintf(stderr, "no %s fallback for U+%x", expected, codepoint);
  if (set) FcFontSetDestroy(set);
  FcPatternDestroy(pattern);
  return !found;
}

int main(void) {
  if (!FcInit()) return 1;
  int result = match("monospace", "Hack", 0) || match("sans-serif", "DejaVu Sans", 0) || match("sans", "DejaVu Sans", 0) || match("serif", "DejaVu Sans", 0) || match("monospace", "DejaVu Sans", 0x0633);
  result = result || available(0x0915, "Noto Sans Devanagari", 0) ||
    available(0x0e01, "Noto Sans Thai", 0) || available(0x4e2d, "Noto Sans CJK SC", 0) ||
    available(0x1f600, "Noto Color Emoji", 1);
  FcFini();
  return result;
}
""",
    )
    let binary = fp"{tmp}/proof"
    run $cc fp"{tmp}/proof.c" f"-I{root}/usr/include" f"-L{root}/usr/lib" "-lfontconfig" "-o" $binary
    env ({LD_LIBRARY_PATH: fp"{root}/usr/lib".display(), FONTCONFIG_SYSROOT: root.display(), FONTCONFIG_FILE: "/etc/fonts/fonts.conf", HOME: tmp.display()}) {
      run $binary
    }
  }
  print "fontconfig ok: clean-root generic families and multilingual fallback"
}
