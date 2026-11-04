# Shared font stack

Laputa packages FreeType, HarfBuzz, Fontconfig, and libpng independently. Their
public interfaces are the upstream C ABIs. Programs link to the unversioned
linker names and load the SONAMEs through the musl dynamic loader.

| Package | Version | SONAME | Development interface |
|---|---|---|---|
| `freetype` | 2.15.0 | `libfreetype.so.6` | `freetype2.pc`, `usr/include/freetype2` |
| `harfbuzz` | 15.0.0 | `libharfbuzz.so.0` | `harfbuzz.pc`, `usr/include/harfbuzz` |
| `fontconfig` | 2.18.3 | `libfontconfig.so.1` | `fontconfig.pc`, `usr/include/fontconfig` |
| `libpng` | 1.6.59 | `libpng16.so.16` | `libpng.pc`, `libpng16.pc`, `usr/include/libpng16` |

FreeType uses zlib and libpng, including PNG-compressed embedded color bitmaps.
It enables TrueType and OpenType drivers, CFF, SFNT, the auto-hinter, and
rasterizers. The package retains the PCF and BDF bitmap drivers used by Ghostty. It omits
Type 1, CID Type 1, PFR, Type 42, and Windows FNT drivers. It does not link HarfBuzz, bzip2, or Brotli.

HarfBuzz uses FreeType for its FreeType integration. Its `HB_MINI` build keeps
OpenType shaping and threading; it omits AAT and legacy shaping paths. The
library uses musl and has no shared C++ runtime dependency. Fontconfig uses
FreeType and Expat. The transitive compression and XML SONAMEs are
`libz.so.1` and `libexpat.so.1`.

Fontconfig searches `/usr/share/fonts` recursively. Its configuration maps
`monospace` to Hack and prefers DejaVu Sans for `sans` and `sans-serif`.
`serif` prefers DejaVu Serif when installed and falls back to DejaVu Sans.
The `font-ttf-hack` and `font-ttf-dejavu-sans` packages provide those two
installed families when selected by a profile. DejaVu Sans provides Latin,
Hebrew, and Arabic glyphs; it is not a complete Unicode font. Shaping support
and glyph availability are separate: scripts need a font with the relevant
glyphs and OpenType data. Optional packages provide Noto Sans Devanagari (641,944 bytes), Noto Sans Thai
(218,652 bytes), Noto Sans CJK Simplified Chinese (16,437,364 bytes), and Noto
Color Emoji (10,730,124 bytes). The CJK font covers Han, kana, and Hangul but
uses Simplified Chinese glyph forms. Select these packages when needed; the
default profile does not include them.

Fontconfig can use `/var/cache/fontconfig` and an XDG user cache. A writable
user cache permits an unprivileged process to cache fonts when the system cache
is not writable. Fontconfig can still scan fonts when a cache is unavailable.
The default Ghostty package remains pinned to its existing release until a
shared-font binary is built and qualified; these packages do not change that
pin by themselves.
