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
(218,652 bytes), Noto Sans CJK (19,484,784 bytes), and Noto
Color Emoji (10,730,124 bytes). The CJK collection covers Han, kana, and Hangul with Japanese, Korean,
Simplified Chinese, Traditional Chinese, and Hong Kong faces. Select these packages when needed; the
default profile does not include them.

Fontconfig can use `/var/cache/fontconfig` and an XDG user cache. A writable
user cache permits an unprivileged process to cache fonts when the system cache
is not writable. Fontconfig can still scan fonts when a cache is unavailable.
The default Ghostty package remains pinned to its existing release until a
shared-font binary is built and qualified; these packages do not change that
pin by themselves.

## Local x86_64 qualification

The existing `ghostty-custom` package uses the published `f2024d5d2` artifact.
A local candidate was built from Ghostty commit `6329a774e` with
`-Dapp-runtime=wayland -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
-Dstrip=true -Demit-themes=false -Di18n=false -Dcpu=baseline` and system
integration enabled for FreeType, HarfBuzz, Fontconfig, libpng, and zlib.
Its version string was `1.4.1-dev+000000`. The local archive SHA-256 was
`a7245e40dc52777d3efa13b92577ee4c4dcc179d99da0fd0017620217d1d2595`.
The PM-stripped candidate binary SHA-256 was
`c77048530d640eabed027693d4e2c2b7a5401bff625d78d1f9189948cb2d1f87`.
The checked-in package still uses the published artifact and its original
checksum. The local archive is not a published release.

A temporary package recipe declared the three font libraries as link
dependencies and Hack and DejaVu Sans as runtime-only dependencies. Its
package proof checked the font SONAMEs and absence of RPATH and RUNPATH. Both
that package and the existing package passed `make profile-test` with Linux,
KVM, Tinyland, virgl, keyboard input, screenshot, and session recovery. A
networkless composed root also ran the candidate and failed to load it when
`libharfbuzz.so.0` was absent. An unprivileged Fontconfig consumer selected an
Arabic fallback and populated its XDG cache with an unwritable system cache.

The unique regular-file sizes in the PM-composed `ghostty-custom` runtime
closures were 172,916,318 bytes for the existing package and 175,795,479 bytes
for the candidate. The corresponding stripped executables were 30,787,208 and
27,179,848 bytes. The candidate closure included these shared libraries:

| Library | Bytes |
|---|---:|
| FreeType | 903,984 |
| HarfBuzz | 754,280 |
| Fontconfig | 481,784 |
| libpng | 262,432 |
| Expat | 191,240 |
| zlib | 104,544 |

One guest `smaps_rollup` observation at the profile's idle proof point gave
41,760 KiB RSS, 41,244 KiB PSS, 41,048 KiB private, and 712 KiB shared for
the existing package. The candidate gave 40,788 KiB RSS, 40,269 KiB PSS,
40,068 KiB private, and 720 KiB shared. These single observations are not a
statistical performance comparison. Cold and warm startup, shaping throughput,
rasterization time, and Fontconfig cold-cache time have not been qualified.
AArch64 runtime and package proofs also remain unverified.
