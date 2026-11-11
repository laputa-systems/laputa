# Native-code census

The ELF provider audit in [the font stack](FONT-STACK.md) identifies shared
libraries. It does not see C and C++ linked into an executable. The census
accounts for both for the Tinyland and Ghostty profile
(`qemu-tinyland-ghostty`) and for Play, and it is the starting point for
[LAP-51](rfc/LAP-51-c-free-userspace.md). FFmpeg, codecs, musl, Linux, Mesa
drivers, crabc, and allocators are retained and are counted, not replaced.

## Run it

Build and compose the profile's runtime roots with the existing commands, then
run the audit against the composed root. The three commands are the ones this
document was measured with; the plan is the profile's transitive closure, not
the font-only plan that an earlier `make plan` selection leaves behind:

```bash
make build PKGS="baselayout ca-certificates xsh laputa-pm xinit mdevd-rs seatd-rs doas-rs tinyland ghostty-custom play"
xsh pm.xsh -- repo plan --repo . --target x86_64-linux-musl \
  --root baselayout --root ca-certificates --root xsh --root laputa-pm --root xinit \
  --root mdevd-rs --root seatd-rs --root doas-rs --root tinyland --root ghostty-custom \
  --root play --output .out/census-plan.json
xsh pm.xsh -- root compose .out/census-plan.json --store .out/artifacts/x86_64 \
  --runtime-root baselayout --runtime-root ca-certificates --runtime-root xsh \
  --runtime-root laputa-pm --runtime-root xinit --runtime-root mdevd-rs \
  --runtime-root seatd-rs --runtime-root doas-rs --runtime-root tinyland \
  --runtime-root ghostty-custom --runtime-root play --output .out/census-root
xsh qualification/native-census/census.xsh -- census .out/census-root \
  --plan .out/census-plan.json
```

`make fetch` does not supply Play's release archive when it stops on the
unrelated doas-rs source. Download it and store it under its SHA-256 in
`.cache/sources/sha256/`.

The measured root was composed from the plan at `d4601fa`, where every planned
artifact is in `.out/artifacts/x86_64`. Re-running the sequence at a later
revision first needs `make build` to fill the store for the packages whose
recipes changed. In this environment that build stops at `vulkan-headers`:
CMake's C++ compiler test fails with `ld.lld: error: unable to find library
-lc++` and `-lc++abi` from the composed build root's `/usr/bin/c++` wrapper. I
did not resolve which staged input omits them — `llvm-toolchain` does ship
`usr/lib/llvm23/lib/libc++.a` and `libc++abi.a`, and the wrapper passes
`-L …/usr/lib/llvm23/lib` — so this is an unresolved build-environment
blocker, not a census finding. Every package that does not need a C++ link
builds, and the census above is unaffected because it reads the composed root,
not the recipes.

`census` reads `qualification/native-census/components.json`. For each listed
binary it checks that the exact `DT_NEEDED` set, `RUNPATH`, and every provider
owner match; that each declared static component still has all of its string
markers; and that each marker declared absent is absent. It also fails when a
package that ships ELF files has no provider entry, so a new native package
must be explained before the audit passes. Every unknown needs its evidence and
a step that would settle it, and each carries `settled`. The run prints the
closed and open counts per binary and ends with
`native census verified: N binaries; M attributions open`, so a remaining
attribution is visible in the output rather than assumed away. On this root the
only open entry is `libgallium LLVM byte share`. Negative runs of a removed
marker, a removed provider entry, and a removed `DT_NEEDED` entry each fail.

`symbols` attributes the symbols of an unstripped build to the archives that
were linked into it. It requires the unstripped and released binaries to share
a build ID, and fails when more than 4,096 non-Rust bytes remain unattributed:

```bash
xsh qualification/native-census/census.xsh -- symbols \
  /absolute/path/to/root/usr/bin/player ~/d/play/build-linux/bin/mpv \
  --archive-dirs ~/d/play/.work/deps/linux/lib --archive-dirs /usr/lib \
  --archive-dirs /usr/lib/gcc/x86_64-alpine-linux-musl/15.2.0
```

## Subject revisions

| Subject | Identity |
|---|---|
| Laputa | `d4601fa` or later; XSH `4da11c9e1` |
| Root | x86_64, 31 packages, 1,535 unique regular files, 332,862,988 bytes, 48 ELF files |
| Ghostty | joshuarli/ghostty `c4f036c72`; release archive SHA-256 `a269c413…efd93b`; installed executable SHA-256 `b26f67cf…9144f0` |
| Play | v0.43.2 at `58e8ffd05bbd`; release archive SHA-256 `1b259f2c…7272c1`; `player` SHA-256 `0c69a185…cc688`; build ID `3e03a0eaca019d8b40b01922e93e8edaac4308ed` |

The root figure is what the composed root measures now. An earlier revision of
this document recorded 332,868,952 bytes; composing the same 31-package file
list from the artifacts in the store gives bytes that do not reproduce it, and
I could not reconstruct which artifact carried the difference. Building the
same root before `d4601fa` gives 332,863,084, and after it 332,862,988 — the
96-byte fall is exactly the removed `/usr/lib` RUNPATH strings on doas-rs (16),
mdevd-rs (48), seatd-rs (16), and tinyland (16). The `tinyland` component
therefore expects `runpath` empty, which only holds from `d4601fa` on.

The release `player` is byte-identical to the `dist/player` that a local
`scripts/build-linux.sh` produced in `~/d/play`, so its unstripped sibling
`build-linux/bin/mpv` (same build ID) is valid symbol evidence for the
release. Play's build used rustc 1.100.0-nightly `574ff7d98` (2026-09-14),
GCC 15.2.0 from Alpine, and the FFmpeg runtime 9.0.2+20261107. The `player`
SHA-256 above is the release archive member. The installed
`usr/bin/player` hashes differently (`4d1bee19…f24d01`) because PM runs
`llvm-strip --strip-unneeded` on every declared binary, which rewrites the
section headers of the already-stripped release; `.text` is byte-identical
between the two and the build ID is unchanged, so `symbols` still applies.

Ghostty has no unstripped counterpart. Its static code is attributed by build
recipe and string markers on the release, and by symbol sizes from a
`-Dstrip=false` build of the same pinned commit (see the Ghostty section).

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
does not install, 20 packages: `llvm-toolchain`, `llvm-static`, `cargo`,
`cmake`, `muon`, `samurai`, `pkgconf`, `tic`, `linux-headers`, `gnu-stubs`,
`expat`, `vulkan-headers`, `wayland-dev`, `wayland-protocols`,
`wayland-libs-server`, `wayland-libs-cursor`, and the four optional font packs.
The set tracks the build-system transition: at `d4601fa` the Meson and Ninja
packages still build through `muon` and `samurai`, and later revisions replace
both with `gluon`, so the count falls to 19 without changing the installed
root.

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

**Unknowns.** The pinned commit was rebuilt locally with
`-Dstrip=false` and the same `-Doptimize=ReleaseFast -Dcpu=baseline` flags, so
the shares below are measured, not inferred. The local build is not
byte-identical to the CI artifact (its `.text` is 9,242,030 bytes against
9,064,091 and its `.rodata` 17,277,936 against 17,260,592, about 2% larger), so
these are shares of the pinned source rather than of the shipped bytes; the
component set and the stripped markers agree with the release.

| Subject | Why it was unknown | What settled it |
|---|---|---|
| Highway 1.2.0 | `addSimd` links it whenever `-Dsimd` is on, but the stripped binary has no Highway string | the unstripped build: `nm -S` finds 12 `hwy::` symbols (3,545 bytes) and 16 Highway-instantiated `ghostty::N_{AVX2,SSE2,SSE4,SSSE3}` kernels (5,576 bytes); `build.zig.zon` pins highway 1.2.0 |
| Byte share of every component above | the executable is stripped | symbol bytes by archive and object membership, below |
| compiler-rt and translate-c output | no version strings | 42 Zig-runtime symbols (20,913 bytes), one compiler-rt arithmetic helper (207 bytes), no `translate-c` marker, so no C enters this way |

| Component | Symbols | Bytes |
|---|---:|---:|
| SPIRV-Cross | 4,449 | 1,735,020 |
| glslang | 2,891 | 1,635,275 |
| Dear ImGui with dcimgui | 2,738 | 924,031 |
| oniguruma | 1,051 | 469,786 |
| wuffs (prefix) | 508 | 228,922 |
| simdutf | 337 | 222,065 |
| glad GL | 4 | 55,031 |
| stb_image and resize (prefix) | 40 | 36,445 |
| Highway (11 runtime symbols plus 16 instantiated kernels) | 26 | 6,716 |
| sound control socket | 12 | 4,996 |
| glad EGL | 4 | 130 |

The named symbols sum to 5,318,417 bytes. The remainder, 21,018,930 bytes in
12,760 symbols, is Ghostty's own Zig code and runtime plus the Wayland protocol
glue, which the build emits per protocol rather than as one archive. `symbols`
needs a shared build ID and Ghostty's release has none, so this attribution is
a separate check from the Play one. Highway's runtime part alone is the
`hwy::` symbols at 3,545 bytes; the rest is the four-target dispatch kernels
Ghostty instantiates from Highway headers, which is why a stripped binary has
no Highway string: they are unnamed at the C level and only the mangled
`ghostty::N_*` names survive.

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
| glslang | `e1b562a8` | 4,154 | 1,494,257 |
| libplacebo | 7.387.0 | 1,321 | 575,472 |
| libstdc++ | GCC 15.2.0 | 2,397 | 713,649 |
| shaderc | 2026.4 | 200 | 31,478 |
| libgcc and libgcc_eh | GCC 15.2.0 | 110 | 30,386 |
| Rust (the player and its crates) | rustc 1.100.0-nightly | | 2,473,841 |
| Unattributed, not Rust | | 17 | 3,257 |

The 5,000,962 attributed native symbol bytes are 52% of the stripped
executable. Symbol sizes do not include section padding, strings, or unwind
tables. The earlier table named `libshaderc.a`, which lacks the `shaderc_util`
front end; `linux-link.args` names `libshaderc_combined.a`, and with that
archive the residue drops from 25,121 to 3,257 bytes, so `play_symbols`
archives the combined archive and caps residue at 4,096 bytes. The 17 remaining
symbols are `crt`, `main`, `_init`, and `_fini`, `rust_eh_personality`, the four
libm forwarders, and `completed.1`/`object.0` from Rust's self-contained musl
libc — each accounted for, none unexplained. The pinned build-only inputs are
Vulkan-Headers 1.4.363.0, SPIRV-Headers `04fd3caa`, fast_float 8.3.2 (a
libplacebo third-party header), and the Python packages glad2, Jinja2, and
MarkupSafe used by libplacebo's build. Rust crates do not compile C for Linux:
`cc` serves only the macOS bridge and `wayland-backend`, and `compress2` is the
only imported zlib function.

**Unknowns, now closed.**

- SPIRV-Headers is headers only, and no member of `libSPIRV-Tools.a` or
  `libSPIRV.a` names a SPIRV-Headers translation unit.
- `cc` 1.11.1 is reached only from `player-display` and `wayland-backend`.
  `player-display/build.rs` compiles `bridge/metal_window.m` only when
  `CARGO_CFG_TARGET_OS == macos`, which Linux never sets; `wayland-backend`
  compiles its two `log_shim.c` files only under its `log` feature, and
  `cargo tree -e features` shows neither consumer enabling it. No Linux C is
  compiled by a Rust build script.

## Other binaries in the root

**Mesa.** `libgallium-26.2.4.so` (68,098,416 bytes) and `libvulkan_lvp.so`
(71,845,240) each embed LLVM 23.1.5 from `llvm-static` with its libc++abi, and
libgallium also carries LLVM's libunwind. Both are stripped. `libvulkan_lvp.so`
exports its LLVM symbols dynamically: 22,663 `llvm::` symbols carry 12,434,304
of the library's 15,246,973 dynamic symbol bytes — 82% of that symbol table and
17% of the 71,845,240-byte file, before section padding. `libgallium-26.2.4.so` exports only 83
symbols through a version script and links `llvm-static` with
`-Wl,--gc-sections`; the string `LLVM version 23.1.5` is present but no
`llvm::` symbol survives, so its LLVM share needs a link map
(`-Wl,-Map`) from the Mesa package build, which this census does not run. That
one byte share remains open.

**tinyland.** It needs `libseat.so.1` (seatd-rs) and `libc.so` (musl) and has
no `RUNPATH`. Its only static native code observed is the LLVM libunwind
in Rust's musl runtime plus clang's CRT. The `could not load
libwayland-server.so` string is wayland-backend's `types::server` `Display`
impl, which compiles in whichever backend is selected. This build selects only
the `rs` backend: the binary imports no `dlopen` or `dlsym`, has no
`libwayland-server.so.0` string, and carries none of the C entry points the
`sys` backend resolves (`wl_display_create`, `wl_global_create`,
`wl_display_run`). The string is therefore unreachable, not a loaded library.
The clang 23.1.5 object in `.comment` is `usr/lib/crtbeginS.o` from the
`llvm-toolchain` package (its other CRT objects and the musl CRT are clang
23.1.0-rc2; rustc 1.99.0 supplies the Rust objects).

**seatd, mdevd, doas.** Each has no `RUNPATH`. seatd and mdevd need only
`libc.so`; doas needs `libcrypt.so` as well, both from musl. `libseat.so.1`
(25,120 bytes) is the upstream C client: clang 23.1.5 and LLD 23.1.5, cut from
the seatd release the recipe pins at SHA-256 `302564d5`, exporting the 11
upstream `libseat_*` entry points and dlopening no backend. It is C, and the
Rust daemon serves the socket it talks to.

**xsh and xsht.** These pre-built seed binaries have no `DT_NEEDED` entries. They
incorporate mimalloc (`libmimalloc-sys 0.1.49`), zstd 1.5.7 (`zstd-sys
2.1.0`), and liblzma (`liblzma-sys 0.4.9`) as C, beside the Rust
zlib-rs 0.6.3, libbz2-rs-sys 0.2.5, and lzma-rust2 0.16.5. The C symbols are
present: 71 `lzma_*`, 236 `ZSTD_*`, and 99 `mi_*` in `xsh`. The `.comment`
GCC 9.4.0 object is Rust's bundled musl self-contained sysroot — `libc.a`,
`crt1.o`, `Scrt1.o`, `crti.o`, `crtn.o`, and `libunwind.a` — which rustc
1.100.0-nightly 2026-09-14 ships for the musl target; the three C archives are
clang 23.1.4/23.1.5. The xz-utils inside `liblzma-sys` 0.4.9 is 5.8.4, from the
crate's `xz/NEWS`.

**Existing closure audit.** The shared-stack closure audit
(`qualification/ghostty-shared/closure.xsh`) passed on this root before its
candidate recipe was removed; `fe249f5` deleted it with that recipe, so the
census is now the only re-runnable check on this root. The Rust packages (doas,
mdevd, seatd, tinyland, and the other Rust daemons) no longer pass
`-rpath /usr/lib`, which the default search path made redundant. The audit
accepted a `RUNPATH` only when it was exactly `$ORIGIN/../lib` on a `usr/bin`
file or `$ORIGIN` on a `usr/lib` file, both of which resolve to `/usr/lib`;
Play and the prebuilt FFmpeg archive carry these and the repository has no tool
that rewrites them.

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
   wuffs, glslang, SPIRV-Cross, Highway in Ghostty; shaderc, glslang,
   SPIRV-Tools, libplacebo in Play). These change the upstream fork's or Play's
   sources, not a Laputa package. Each now has its unstripped baseline and
   per-component byte share above. A candidate needs an output-equivalence
   corpus (regular-expression matches for oniguruma; shader module validation
   and rendered frames for the shader stack). Play's libplacebo depends on
   shaderc for its generated GLSL, so a front-end swap needs the whole shader
   pipeline rendered identically before it is considered.
