# Native-code census

The ELF provider audit in [the font stack](FONT-STACK.md) identifies shared
libraries. It does not see C and C++ linked into an executable. The census
accounts for both for the Tinyland and Ghostty profile
(`qemu-tinyland-ghostty`) and for Play, and it is the starting point for
[LAP-51](rfc/LAP-51-c-free-userspace.md). FFmpeg, codecs, musl, Linux, Mesa
drivers, crabc, and allocators are retained and are counted, not replaced.

## Run it

Build and compose the profile's runtime roots with the existing commands, then
run the audit against the composed root:

```bash
make build PKGS="baselayout ca-certificates xsh laputa-pm xinit mdevd-rs seatd-rs doas-rs tinyland ghostty-custom play"
xsh pm.xsh -- root compose .out/world/x86_64/plan.json --store .out/artifacts/x86_64 \
  --runtime-root baselayout --runtime-root ca-certificates --runtime-root xsh \
  --runtime-root laputa-pm --runtime-root xinit --runtime-root mdevd-rs \
  --runtime-root seatd-rs --runtime-root doas-rs --runtime-root tinyland \
  --runtime-root ghostty-custom --runtime-root play --output .out/census-root
xsh qualification/native-census/census.xsh -- census /absolute/path/to/.out/census-root \
  --plan .out/world/x86_64/plan.json
```

`make fetch` does not supply Play's release archive when it stops on the
unrelated doas-rs source. Download it and store it under its SHA-256 in
`.cache/sources/sha256/`.

`census` reads `qualification/native-census/components.json`. For each listed
binary it checks that the exact `DT_NEEDED` set, `RUNPATH`, and every provider
owner match; that each declared static component still has all of its string
markers; and that each marker declared absent is absent. It also fails when a
package that ships ELF files has no provider entry, so a new native package
must be explained before the audit passes. Every unknown needs its evidence and
a step that would settle it. Negative runs of a removed marker, a removed
provider entry, and a removed `DT_NEEDED` entry each fail.

`symbols` attributes the symbols of an unstripped build to the archives that
were linked into it. It requires the unstripped and released binaries to share
a build ID, and fails when more than 65,536 non-Rust bytes remain unattributed:

```bash
xsh qualification/native-census/census.xsh -- symbols \
  /absolute/path/to/root/usr/bin/player ~/d/play/build-linux/bin/mpv \
  --archive-dirs ~/d/play/.work/deps/linux/lib --archive-dirs /usr/lib \
  --archive-dirs /usr/lib/gcc/x86_64-alpine-linux-musl/15.2.0
```

## Subject revisions

| Subject | Identity |
|---|---|
| Laputa | `ee1fb0c` plus this change; XSH `4da11c9e1` |
| Root | x86_64, 31 packages, 1,535 unique regular files, 332,868,952 bytes, 48 ELF files |
| Ghostty | joshuarli/ghostty `c4f036c72`; release archive SHA-256 `a269c413…efd93b`; installed executable SHA-256 `b26f67cf…9144f0` |
| Play | v0.43.2 at `58e8ffd05bbd`; release archive SHA-256 `1b259f2c…7272c1`; `player` SHA-256 `0c69a185…cc688`; build ID `3e03a0eaca019d8b40b01922e93e8edaac4308ed` |

The release `player` is byte-identical to the `dist/player` that a local
`scripts/build-linux.sh` produced in `~/d/play`, so its unstripped sibling
`build-linux/bin/mpv` (same build ID) is valid symbol evidence for the
release. Play's build used rustc 1.100.0-nightly `574ff7d98` (2026-09-14),
GCC 15.2.0 from Alpine, and the FFmpeg runtime 9.0.2+20261107.

Ghostty has no unstripped counterpart, so its static code is attributed by
build recipe and string markers only.

## Providers

Every package with an ELF file in the root has an entry. `retained` and
`retained-exception` stay native under the LAP-51 scope. `replacement-candidate`
is native code a Rust replacement could plausibly remove.

| Package | Language | Disposition | Role |
|---|---|---|---|
| `alsa-lib` | C | retained | Play audio |
| `ffmpeg` | C | retained-exception | FFmpeg runtime and CLI |
| `freetype` | C | replacement-candidate | glyph rasterizer |
| `harfbuzz` | C++ | replacement-candidate | shaper |
| `libdrm` | C | retained | DRM for Mesa |
| `libffi` | C | retained | installed with the Wayland client |
| `libpng` | C | replacement-candidate | FreeType PNG bitmaps |
| `libudev-zero` | C | retained | `libudev.so.1` for lavapipe |
| `libva` | C | retained-exception | VA-API for the FFmpeg runtime |
| `libxkbcommon` | C | replacement-candidate | Ghostty keyboard translation |
| `mesa` | C/C++ | retained-exception | EGL, virgl, lavapipe, static LLVM |
| `musl` | C | retained-exception | libc and loader |
| `seatd-rs` | Rust and C | replacement-candidate | Rust daemon, C `libseat.so.1` client |
| `vulkan-loader` | C++ | retained | `libvulkan.so.1` |
| `wayland-libs-client` | C | replacement-candidate | Wayland client library |
| `zlib` | C | replacement-candidate | `libz.so.1` for Play |
| `ghostty-custom`, `play` | Zig or Rust with static C/C++ | prebuilt-release | below |
| `rust-fontconfig`, `tinyland`, `doas-rs`, `mdevd-rs`, `xsh` | Rust (xsh also static C) | rust | below |

Declared dependencies that no ELF file in the root imports: `play` declares
`libva`, which only the FFmpeg runtime links; `libdrm` declares `libudev-zero`
and `libudev-zero` declares `hwdata`, neither imported by an ELF file;
`libxkbcommon` declares `xkeyboard-config` as data. The root also plans, but
does not install, 19 packages: `llvm-toolchain`, `llvm-static`, `cargo`,
`cmake`, `gluon`, `pkgconf`, `tic`, `linux-headers`, `gnu-stubs`,
`expat`, `vulkan-headers`, `wayland-dev`, `wayland-protocols`,
`wayland-libs-server`, `wayland-libs-cursor`, and the four optional font packs.

## Ghostty

`usr/bin/ghostty-custom` is 27,206,760 bytes: 9,064,091 of `.text` and
17,260,592 of `.rodata`. It has no `RUNPATH`.

**Shared providers.** `libfreetype.so.6` (freetype), `libharfbuzz.so.0`
(harfbuzz), `librust_fontconfig.so.5.0.2` (rust-fontconfig), `libEGL.so.1`
(mesa), `libwayland-client.so.0` (wayland-libs-client), `libxkbcommon.so.0`
(libxkbcommon), and musl.

**Static native code.** The release workflow builds with
`zig build -Dapp-runtime=wayland -Doptimize=ReleaseFast -Dstrip=true
-Demit-themes=false -Di18n=false -Dcpu=baseline
-Dfont-backend=rust_fontconfig_freetype -fsys=freetype -fsys=harfbuzz
-fsys=libpng -fsys=zlib` on Alpine with Zig 0.17.0. The default OpenGL
renderer, `-Dinspector`, and `-Dsimd` are on, `sentry` is off on Linux. Each
component below is a Zig-built C or C++ package under `pkg/`, or a vendored
file, and each has a string marker in the stripped binary.

| Component | Language | Version | Evidence beyond the marker |
|---|---|---|---|
| glslang | C++ | source 14.2.0, stamped 13.1.1 | the tarball is glslang-14.2.0; `pkg/glslang/override/glslang/build_info.h` hard-codes 13.1.1, which is the binary's version string |
| SPIRV-Cross | C++ | `476f384e` | `pkg/spirv-cross` fetches that commit |
| oniguruma | C | 6.9.9 | `pkg/oniguruma/build.zig` |
| Dear ImGui with dcimgui | C++ | 1.92.5-docking | the binary reports `Dear ImGui 1.92.5 (19250)` |
| wuffs | C | `7411f488` | `pkg/wuffs` |
| stb_image and resize | C | vendored | `src/stb/stb.c`, PNG only |
| simdutf | C++ | 5.2.8 | `pkg/simdutf`; implementation names `haswell`, `westmere`, `fallback` |
| glad GL and EGL loaders | C | vendored | `vendor/glad/src/gl.c`, `glad_egl.c` |
| Wayland protocol glue | C | generated | wayland-scanner output |
| sound control socket | C | first party | `src/sound/control.c` |
| libc++abi and libunwind | C++ | Zig 0.17.0 bundle | `link_libcpp`; Zig supplies both |

Libraries absent from the binary by marker: Sentry and Breakpad, libpng,
and zlib's own messages (wuffs carries its own deflate).

**Unknowns.**

| Subject | Why | What would settle it |
|---|---|---|
| Highway 1.2.0 | `addSimd` links it whenever `-Dsimd` is on, but the stripped binary has no Highway string | a `-Dstrip=false` build and `nm`, or the Zig link command from `--verbose-link` |
| Byte share of every component above | the executable is stripped | the same unstripped build, attributed by archive membership as `symbols` does for Play |
| compiler-rt and translate-c output | no version strings | the unstripped build and the Zig 0.17.0 sources |

## Play

`usr/bin/player` is 9,574,616 bytes with `RUNPATH $ORIGIN/../lib`.

**Shared providers.** `libz.so.1` (zlib), `librust_fontconfig.so.5.0.2`,
`libharfbuzz.so.0`, `libfreetype.so.6`, `libavformat.so.63`,
`libavcodec.so.63`, `libswscale.so.10`, and `libavutil.so.61` (ffmpeg),
`libasound.so.2` (alsa-lib), `libvulkan.so.1` (vulkan-loader),
`libwayland-client.so.0`, and musl. `libva` is reached through the FFmpeg
libraries, not by Play. The only use of zlib is `compress2` for screenshots.

**Static native code.** `crates/player-output/linux-link.args` names
`libplacebo.a`, `libshaderc_combined.a`, `/usr/lib/libstdc++.a`, and
`libgcc.a`; `scripts/build-linux.sh` adds `-static-libgcc`.
`scripts/build-deps-linux.sh` pins the sources and verifies each source by
SHA-256. The unstripped build attributes symbols to the archives that
define them:

| Component | Version | Symbols | Bytes |
|---|---|---:|---:|
| SPIRV-Tools | `ef96ed76` | 9,319 | 2,155,720 |
| glslang | `e1b562a8` | 4,090 | 1,486,386 |
| libplacebo | 7.387.0 | 1,321 | 575,472 |
| libstdc++ | GCC 15.2.0 | 2,396 | 713,641 |
| shaderc | 2026.4 | 188 | 17,493 |
| libgcc and libgcc_eh | GCC 15.2.0 | 110 | 30,386 |
| Rust (the player and its crates) | rustc 1.100.0-nightly | | 2,473,841 |
| Unattributed, not Rust | | | 25,121 |

The 4,979,098 attributed native symbol bytes are 52% of the stripped
executable. Symbol sizes do not include section padding, strings, or unwind
tables. The pinned build-only inputs are Vulkan-Headers 1.4.363.0,
SPIRV-Headers `04fd3caa`, fast_float 8.3.2 (a libplacebo third-party header),
and the Python packages glad2, Jinja2, and MarkupSafe used by libplacebo's
build. Rust crates do not compile C for Linux: `cc` serves only the macOS
bridge and `wayland-backend`, and `compress2` is the only imported zlib
function.

**Unknowns.**

| Subject | Why | What would settle it |
|---|---|---|
| Linux C compilation by Rust build scripts | `cc` appears in `Cargo.lock` | `cargo tree --target x86_64-unknown-linux-musl -e build,normal` in `~/d/play` |
| SPIRV-Headers objects | headers only, so none is expected | archive membership of `libSPIRV-Tools.a` |

## Other binaries in the root

**Mesa.** `libgallium-26.2.4.so` (68,098,416 bytes) and `libvulkan_lvp.so`
(71,845,240) each embed LLVM 23.1.5 from `llvm-static` with its libc++abi, and
libgallium also carries LLVM's libunwind. LLVM's share of each library is
unknown until a link map or unstripped build exists.

**tinyland.** It needs `libseat.so.1` (seatd-rs) and `libc.so` (musl) and has
no `RUNPATH`. Its only static native code observed is the LLVM libunwind
in Rust's musl runtime. It carries the string `could not load
libwayland-server.so` although the profile forbids `wayland-libs-server`;
whether that path is reachable is unknown (`cargo tree -e features -i
wayland-sys`, then a guest run without the library). One object compiled by
clang 23.1.5 in its `.comment` is unattributed.

**seatd, mdevd, doas.** Each has no `RUNPATH`. seatd and mdevd need only
`libc.so`; doas needs `libcrypt.so` as well, both from musl. `libseat.so.1`
(25,120 bytes) is the upstream C client; its source language and backends
remain to be read from the recipe.

**xsh and xsht.** These pre-built seed binaries have no `DT_NEEDED` entries. They
incorporate mimalloc (`libmimalloc-sys 0.1.49`), zstd 1.5.7 (`zstd-sys
2.1.0`), and liblzma (`liblzma-sys 0.4.9`) as C, beside the Rust
zlib-rs 0.6.3, libbz2-rs-sys 0.2.5, and lzma-rust2 0.16.5. Their `.comment`
names GCC 9.4.0; which objects it compiled is unknown (compare the `.comment`
of the three C archives in the XSH cargo target). The xz-utils revision inside
`liblzma-sys` is also unread.

**Existing closure audit.** The shared-stack closure audit passed on this
root before its candidate recipe was removed. The Rust packages (doas, mdevd, seatd, tinyland, and the other
Rust daemons) no longer pass `-rpath /usr/lib`, which the default search path
made redundant. The audit accepts a `RUNPATH` only when it is exactly
`$ORIGIN/../lib` on a `usr/bin` file or `$ORIGIN` on a `usr/lib` file, both of
which resolve to `/usr/lib`; Play and the prebuilt FFmpeg archive carry these
and the repository has no tool that rewrites them.

## Replacement gates

Promotion needs all four gate classes for a candidate. These gates apply
before any default changes. None of them has been run for a replacement, and
this document replaces nothing.

**Common to every candidate.**

- Correctness: a differential corpus against the C library as oracle, driven
  through the real consumer (Ghostty's font-filtered Zig tests: 206 pass,
  13 skip; Play overlay and subtitle rendering; guest proofs), with every
  skip reported rather than counted.
- Failure: malformed and hostile inputs and allocation, I/O, and disconnect
  failures give the same error class as the oracle, with no unwinding across the C
  ABI, and a fuzz corpus run.
- Closure: `census.xsh` passes with the provider entry updated; the consumer's
  `DT_NEEDED` set shrinks by the replaced SONAME and gains nothing; `nm -D`
  shows the same exported symbol set and `SONAME`; the new provider adds no
  `cc` or `-sys` crate (checked by adding the old library's marker to
  `absent`); unique installed bytes are reported before and after.
- Performance: at least five interleaved samples of baseline and candidate
  with host-readiness checks before and after, median CPU time with range,
  and no regression larger than the observed spread. Startup and idle RSS use
  the existing guest method in [the font stack](FONT-STACK.md).

**Candidates, in the order LAP-51 prioritizes them.**

1. The seatd client (`libseat.so.1`; sole consumer tinyland). Oracle: the C
   client against the Rust seatd daemon. Correctness covers open seat, open
   and close device, disable acknowledgement, session switch, and device-FD
   ownership. Failure covers daemon disconnect, denied open, `EINTR`, and FD
   exhaustion, and must fail closed. Closure target: tinyland's `DT_NEEDED`
   becomes `libc.so` alone and `libseat.so.1` leaves the root. Performance:
   seat open latency and tinyland guest startup.
2. libxkbcommon (consumer Ghostty). The contract is Ghostty's undefined `xkb_*`
   import list, taken from `nm -D --undefined-only`. Correctness: keysym and
   UTF-8 output for every keycode, modifier state, and group across the
   layouts the proofs use, plus compose sequences and modifier masks.
   Failure: malformed keymap text and a missing XKB directory. Closure:
   `libxkbcommon.so.0` leaves and the `xkeyboard-config` data dependency is
   either kept or replaced by the new provider's data. Performance: keymap
   compile time and per-key cost.
3. zlib as a Rust `libz.so.1` (zlib-rs). Consumers: Play, FreeType, and libpng.
   Output bytes need not match, so correctness is round-trip plus inflate by
   the C oracle at every level, streaming across split inputs, gzip, checksums,
   and return codes. Failure: truncated, corrupt, and bomb inputs; allocator
   hooks. Closure: identical exported symbol set. Performance: `compress2`
   on screenshot-sized RGBA and inflate of compressed PCF fonts. Does not touch
   `ffmpeg-build`.
4. FreeType, HarfBuzz, and libpng together (Skrifa, Swash, Zeno, HarfRust).
   Both applications must move at once to keep one distribution provider.
   Correctness reaches final pixels: fallback boundaries, combining
   sequences, ZWJ emoji, color and bitmap fonts, variable axes, metrics, and
   the Arabic corpus. Failure: the FreeType fuzz corpus and malformed fonts.
   Performance: the 100,000-iteration Arabic shape-and-rasterize workload
   (362.177 ms median CPU with the LTO FreeType) and the startup and idle
   memory pairs. Closure: `libfreetype.so.6`, `libharfbuzz.so.0`, and
   `libpng16.so.16` all leave.
5. Wayland client library. Defer: Mesa's EGL Wayland platform imports the C
   API, so a replacement must pass the same ABI gates for Mesa, Ghostty, and
   Play before it can remove the SONAME.
6. Static components inside prebuilt releases (oniguruma, simdutf, stb,
   wuffs, glslang, SPIRV-Cross in Ghostty; shaderc, glslang, SPIRV-Tools,
   libplacebo in Play). These change the upstream fork's or Play's sources,
   not a Laputa package. A candidate needs the unstripped baseline from the
   unknowns above, a per-component byte share, and an output-equivalence corpus
   (regular-expression matches for oniguruma; shader module validation and
   rendered frames for the shader stack). Play's libplacebo depends on shaderc
   for its generated GLSL, so a front-end swap needs the whole shader pipeline
   rendered identically before it is considered.
