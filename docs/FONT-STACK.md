# Shared font stack

Laputa packages FreeType, HarfBuzz, Fontconfig, and libpng independently. Their
public interfaces are the upstream C ABIs. Programs link to the unversioned
linker names and load the SONAMEs through the musl dynamic loader.

| Package | Version | SONAME | Development interface |
|---|---|---|---|
| `freetype` | 2.15.0 | `libfreetype.so.6` | `freetype2.pc`, `usr/include/freetype2` |
| `harfbuzz` | 15.0.0 | `libharfbuzz.so.0` | `harfbuzz.pc`, `usr/include/harfbuzz` |
| `fontconfig` | 2.18.3 | `libfontconfig.so.1` | `fontconfig.pc`, `usr/include/fontconfig` |
| `rust-fontconfig` | 5.0.2 (fork tag `v5.0.2-laputa.2`) | `librust_fontconfig.so.5.0.2` | `rust-fontconfig.pc`, `usr/include/rust-fontconfig` |
| `libpng` | 1.6.59 | `libpng16.so.16` | `libpng.pc`, `libpng16.pc`, `usr/include/libpng16` |

FreeType uses zlib and libpng, including PNG-compressed embedded color bitmaps.
It enables TrueType and OpenType drivers, CFF, SFNT, the auto-hinter, and
rasterizers. The package retains the PCF and BDF bitmap drivers used by Ghostty. It omits
Type 1, CID Type 1, PFR, Type 42, and Windows FNT drivers. It does not link HarfBuzz, bzip2, or Brotli.
Revision 3 enables CMake interprocedural optimization with the existing release
optimization level. The resulting library preserves the same SONAME and dependencies.

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

The canonical graphical profile (`ghostty-custom` and `play`) uses
`rust-fontconfig` for discovery and links no `libfontconfig.so.1`. The
`rust-fontconfig` package owns `/etc/fonts/fonts.conf` with the
`/usr/share/fonts` directory and the generic-family aliases above; the library
reads only its `<dir>` and `<alias>` entries, from `$FONTCONFIG_FILE` when set.
The `fontconfig` package ships no configuration file and is no longer a
dependency of any canonical package. Expat is no longer a dependency of
`wayland-libs-client`, whose library never linked it, so it leaves the
canonical closure; `wayland-scanner` in `wayland-dev` still links it at build
time. The remaining text of this section describes the retained C Fontconfig
baseline.

Fontconfig can use `/var/cache/fontconfig` and an XDG user cache. A writable
user cache permits an unprivileged process to cache fonts when the system cache
is not writable. Fontconfig can still scan fonts when a cache is unavailable.
The `ghostty-custom` package pins the joshuarli/ghostty release built at
`c4f036c72` with `-Dfont-backend=rust_fontconfig_freetype`. Its executable
needs `libfreetype.so.6`, `libharfbuzz.so.0`, `librust_fontconfig.so.5.0.2`,
`libEGL.so.1`, `libwayland-client.so.0`, `libxkbcommon.so.0`, and musl, with no
RPATH or RUNPATH. Its package proof rejects `libfontconfig.so.1`.

## Local x86_64 qualification

The measurements below compare the earlier `ghostty-custom` release
`f2024d5d2`, which bundled its font stack, with a local C Fontconfig candidate;
neither is the current package. A local candidate was built from Ghostty commit `6329a774e` with
`-Dapp-runtime=wayland -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
-Dstrip=true -Demit-themes=false -Di18n=false -Dcpu=baseline` and system
integration enabled for FreeType, HarfBuzz, Fontconfig, libpng, and zlib.
Its version string was `1.4.1-dev+000000`. The local archive SHA-256 was
`a7245e40dc52777d3efa13b92577ee4c4dcc179d99da0fd0017620217d1d2595`.
The PM-stripped candidate binary SHA-256 was
`c77048530d640eabed027693d4e2c2b7a5401bff625d78d1f9189948cb2d1f87`.
The checked-in package still uses the published artifact and its original
checksum. The local archive is not a published release.

To qualify another x86_64 archive on a Linux KVM host, run
`qualification/ghostty-shared/run.sh /absolute/path/to/ghostty.tar.gz` from
this checkout. Set `XSH_ROOT` if the XSH checkout is not the adjacent `xsh`
directory. The command creates an isolated checkout under `.work/tmp`, hashes
the supplied archive, replaces the x86_64 release source and SHA-256 in the
checked-in `ghostty-custom` recipe with the archive, and runs
`make profile-test`. The checked-in recipe and proof are otherwise unchanged.
It reuses the existing seed, source cache, and package artifact cache. The
archive must contain the candidate executable named `ghostty`. The command
does not publish or change the release package pin.

The qualification recipe therefore declares FreeType, HarfBuzz, and
rust-fontconfig as link dependencies, with Hack as a runtime-only font. Its
package proof checks the font SONAMEs and absence of RPATH and RUNPATH. Both
that package and the existing package passed `make profile-test` with Linux,
KVM, Tinyland, virgl, keyboard input, screenshot, and session recovery. A
networkless composed root also ran the candidate and failed to load it when
`libharfbuzz.so.0` was absent. An unprivileged Fontconfig consumer selected an
Arabic fallback and populated its XDG cache with an unwritable system cache.

For a composed candidate root, run
`xsh qualification/ghostty-shared/closure.xsh -- /absolute/path/to/root`.
The audit requires one independently owned provider for each font SONAME,
checks loader symlinks, rejects private library search paths, and checks every
ELF dependency against the installed provider and declared dependency closure.
Musl library aliases resolve to their actual package owner. The current root
passes with 19 packages and 26 ELF files. Negative checks reject an added
duplicate FreeType provider and a removed FreeType dependency declaration.
The [native-code census](NATIVE-CENSUS.md) extends this provider audit to
statically incorporated C and C++.

Ghostty's existing font-filtered Zig tests also run against that composed
runtime: 206 pass, 13 skip, and zero fail. The test executable imports the
three font SONAMEs without RPATH or RUNPATH. A networkless namespace supplies
only the composed root's libraries and fonts, the repository's read-only
reference images, a minimal test-user identity, and writable test scratch.
This covers font discovery, FreeType color and bitmap formats, ligatures,
shaping, glyph caches, and reference-image comparisons. Six skips select other
backends, three are pre-existing disabled complex-script cases, and four need
specific uninstalled international font families. The package proofs exercise
the separately packaged international corpus. Skipped Zig cases are not
counted as passing, and no test was disabled for this qualification.

Fresh PM composition includes 13 runtime artifacts for the existing package and
19 for the candidate with FreeType revision 3. Count each regular file once,
including development interfaces and the generated root receipt. Symlinks do
not duplicate their targets. These are installed bytes, not archive sizes:

| Measurement | Existing package | Shared-font candidate |
|---|---:|---:|
| Unique runtime closure | 172,913,946 | 175,776,899 |
| Stripped Ghostty executable | 30,787,208 | 27,179,848 |
| Additional installed bytes | — | 2,862,953 |

The candidate closure includes these shared libraries:

| Library | Bytes |
|---|---:|
| FreeType | 888,648 |
| HarfBuzz | 754,280 |
| Fontconfig | 481,784 |
| libpng | 262,432 |
| Expat | 191,240 |
| zlib | 104,544 |

After the LTO revision, five alternating pairs booted the two PM-produced
Tinyland profiles in fresh x86_64/KVM guests with two vCPUs, 1,536 MiB RAM,
and virgl. Each accepted run passed readiness checks immediately before and
after execution. The host page cache was warm. Each guest first launched
Ghostty with an empty font cache, then launched it again with three generated
cache files. The same terminal color marker had to become visible.

The host measured a virtio-serial launch trigger through detection in a QMP
screenshot. These are upper bounds that include dispatch, screenshot, and
polling overhead, not isolated process initialization or GPU presentation times.
The startup ranges overlap. This method demonstrates no speed difference;
the limiting startup component has not been independently identified.

| Measurement | Existing package median (range) | Shared-font candidate median (range) |
|---|---:|---:|
| Empty font cache startup upper bound, ms | 96.877 (84.852–119.302) | 109.891 (99.100–160.126) |
| Populated font cache startup upper bound, ms | 82.463 (76.875–103.630) | 91.308 (78.234–105.627) |
| Idle RSS, KiB | 41,560 (41,420–41,680) | 40,840 (40,736–40,924) |
| Idle PSS, KiB | 41,041 (40,918–41,170) | 40,317 (40,223–40,427) |
| Idle private memory, KiB | 40,840 (40,724–40,964) | 40,100 (40,032–40,232) |
| Idle shared memory, KiB | 696 (692–724) | 716 (692–740) |

The guest read Ghostty's `smaps_rollup` after two seconds at the same idle
terminal proof point. Private and shared totals include their clean, dirty,
and hugetlb fields. These observations cover one terminal per guest and do
not measure deduplication across multiple applications. The shared design
provides distribution ownership even when a single application's total closure
grows or startup does not improve.

Five alternating pairs per workload passed host readiness checks before and
after the measurement session. A warm `ghostty --version` process had median wall times of
0.785 ms (range 0.544–0.967) for the existing binary and 0.672 ms (range
0.641–0.984) for the candidate. The ranges overlap. This measures CLI loading,
not graphical startup.

A separate process shapes and rasterizes the same Arabic text 100,000 times
with DejaVu Sans. Five rotating, readiness-qualified samples per configuration
produce the same checked glyph-and-bitmap accumulator. Initialization is included:

| Configuration | Median CPU, ms | Range, ms | FreeType bytes |
|---|---:|---:|---:|
| Previous bundled stack | 341.174 | 338.002–342.891 | Included in Ghostty |
| Shared stack before LTO | 375.422 | 374.337–376.416 | 903,984 |
| Shared stack with LTO | 362.177 | 360.130–369.719 | 888,648 |
| Shared stack with LTO and `-Oz` | 402.755 | 400.531–405.887 | 580,616 |

The production package selects LTO with the existing optimization level.
Its library is byte-identical to the measured LTO variant. That variant reduces
CPU cost against the same-version shared baseline, while `-Oz` regresses it.
The previous bundled stack is still faster in this workload. It uses older
FreeType and HarfBuzz versions, so this comparison cannot attribute the gap to
dynamic linkage. An untimed million-iteration profile attributes about 74% of
sampled CPU work to FreeType. The workload measures shaping and rasterization,
not graphical startup or complete application performance.

A Fontconfig process scanned one Hack font into a fresh cache for each run,
with the operating system page cache warm. The selected font and cache creation
were checked. Median CPU time was 6.031 ms (range 5.949–6.492) with the
bundled Fontconfig and 4.821 ms (range 4.637–4.970) with the shared package.
These isolated measurements do not establish the cost of a real font directory
or the contribution to graphical startup. Their limiting factors remain
unverified.

A manual AArch64 cross-build used the same font feature choices with Zig 0.17
and ran under `qemu-aarch64` with a private Alpine musl loader. The ELF files
had the expected SONAMEs and no RPATH or RUNPATH. A runtime consumer exercised
Arabic and Hebrew shaping, ligatures, combining marks, variable axes,
Devanagari, Thai, a CJK collection, PNG color emoji, BDF, PCF, and Fontconfig
discovery. Its loader resolved the shared libraries from the private root.
This was not a native PM package build or an AArch64 Ghostty or guest proof.

## Remaining qualification after wind-down

The owner resumed work after the 2026-11-04 wind-down. The repeated graphical
startup and idle-memory observations above now cover the LTO package. The
current local graphical proof and package results remain valid within their
stated scope. Native ARM package and graphical qualification remain open.
No release was published and the production package pin remains unchanged.

After this baseline and Play's SRT/Core Text migrations qualify, execute
[LAP-52](rfc/LAP-52-rust-fontconfig.md) before the broader
[C-free roadmap](rfc/LAP-51-c-free-userspace.md). The cross-repository
[XSH queue](https://github.com/laputa-systems/xsh/blob/master/TODO.md)
records retained source and outstanding checks. macOS execution remains outside this Linux campaign.
