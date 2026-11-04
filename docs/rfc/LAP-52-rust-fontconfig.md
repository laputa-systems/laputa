# LAP-52: Share upstream rust-fontconfig across Ghostty and Play

Status: accepted

## Summary

Adopt upstream rust-fontconfig as Laputa's authoritative font discovery,
matching, and fallback engine. Package one dynamically linked
`librust_fontconfig` for Ghostty and Play. Retain shared FreeType and HarfBuzz,
Play's Rust bidi and line-breaking logic, and native Core Text on macOS.

The owner authorized this campaign on 2026-11-04 with this execution order:

1. Complete the [shared native font stack](../FONT-STACK.md) qualification.
2. Complete Play's SRT and Core Text migrations and their applicable proofs.
3. Execute this rust-fontconfig campaign.
4. Begin the broader [C-free userspace roadmap](LAP-51-c-free-userspace.md).

The two prerequisites must have verified results before implementation starts.
Existing source or architecture documentation alone does not establish a pass.
macOS execution remains outside the current Linux campaign. Preserve the
existing macOS implementation and distinguish its recorded qualification from
Linux tests.

Commit completed changes directly to the owned repositories' default branches.
Use an upstream pull request only when an upstream change is appropriate.
Do not treat this document as release publication authority.

## Motivation

The shared native stack establishes distribution ownership of font libraries.
Replacing discovery once at that boundary avoids private copies in applications.
The replacement removes C Fontconfig and, where no other consumer remains,
Expat from the canonical graphical root.

Upstream's C API is the integration authority. Do not reproduce the Fontconfig
`Fc*` ABI or implement another matching engine. Keep font discovery separate
from shaping, bidi, line breaking, and rasterization. Selecting coverage for a
codepoint does not establish correct shaping of a grapheme cluster.

## Design

### Evaluate and pin upstream

Inspect the latest [upstream source](https://github.com/fschutt/rust-fontconfig),
README, releases, tests, FFI, and recent changes when the campaign starts.
Pin a verified release or commit and its Rust dependency closure for offline
builds. Record licenses and maintenance requirements.

Begin with upstream's FFI, real font parsing, and fallback functionality.
Resolve the actual feature graph for `std`, `parsing`, `ffi`, `async-registry`,
`multithreading`, and `cache`. Verify whether FFI enables the asynchronous
registry and how XML parsing is coupled to metadata parsing at the pinned
revision. Measure costs before removing either facility.

Prefer upstream feature selection. Add only an essential, coherent interface
missing from upstream. Keep changes small enough to update without maintaining
a fork of matching logic.

### Package one versioned library

Create `packages/rust-fontconfig/PKGBUILD.xsh` and `proof.xsh` using Laputa's
existing package conventions. Build x86_64-linux-musl and aarch64-linux-musl.
Install the shared library, C headers, pkg-config metadata, and required
runtime artifacts. Declare exact outputs and actual build and runtime edges.

Retain the upstream `librust_fontconfig` identity. Establish and test a SONAME
and ABI version policy without claiming undocumented upstream stability.
Verify exported layouts and symbols, allocation and release ownership, error
reporting, thread safety, and panic boundaries. Audit the complete runtime
closure for glibc, native Fontconfig, Expat, and host tooling leakage.

Both consumers must resolve the same Laputa provider through the system loader.
Neither application may ship a private copy or statically incorporate another
implementation. Add no daemon or desktop framework.

### Supply deterministic font policy

Use upstream `FcFallbackConfig` and `FcScanConfig` where the pinned API provides
them. Inspect explicit scan-directory and fallback-policy injection through the
C interface. Extend that interface minimally if required. Do not add a general
configuration language or reproduce `fonts.conf` policy.

The policy must support these consumer needs:

- `/usr/share/fonts` and user-installed fonts.
- Explicit families and generic serif, sans-serif, and monospace.
- Weight, slant, stretch, collections, face indices, and variable metadata.
- Unicode coverage and script-sensitive ranked fallback.
- Color emoji and text presentation where upstream supports the distinction.

Retain pure Rust XML parsing initially. Consider separating it from metadata
parsing only after the native policy works and a measured saving justifies an
upstream-compatible change. Keep font files independently packaged and coverage
guarantees distinct from shaping guarantees.

### Reuse bounded cache machinery

Evaluate upstream memory and persistent caches before designing anything new.
Measure cold scanning, metadata construction, cached startup, lookup, fallback,
and memory with the actual installed font set and additional user fonts.

Prefer a verified index prepared during immutable root composition if upstream
supports that arrangement. Validate and bound cached input. Invalidate caches
when fonts change, preserve user-font discovery, and handle corrupt caches
safely. Normal query paths must avoid repeated scans and require no daemon.
Enable parallel or background discovery only when measured benefit justifies
it for Laputa's font counts.

### Migrate Ghostty and Play

Start Ghostty's Linux integration in `src/font/discovery.zig`,
`src/font/DeferredFace.zig`, `src/font/Collection.zig`, and
`src/font/CodepointResolver.zig`. Use upstream C calls for metadata, ranked
fallback, paths, and face indices. Preserve FreeType faces, HarfBuzz shaping,
family selection, bold and italic, monospace preference, ligatures, variable
fonts, emoji, and existing caches. A traditional Fontconfig backend may remain
for other builds. The canonical Laputa build must use the shared replacement.

Migrate Play's Linux text backend to the same C API and provider. A Rust API
prototype must not become a second static production copy. Preserve
international SRT, bidi, Unicode wrapping, OSC text, and glyph and layout
caches. Keep fallback decisions compatible with whole shaping clusters.
Per-character resolution must not split combining sequences, emoji ZWJ
sequences, or complex-script clusters. Preserve native Core Text unchanged.

### Qualify actual discovery and rendering

Compare against the working C Fontconfig baseline using fixed font fixtures.
Exercise selected families and styles, ranked fallback, path and face identity,
coverage, language preferences, emoji presentation, and variable metadata.
Investigate ranking differences rather than requiring accidental ordering
parity with a different defensible policy.

Include Latin, Cyrillic, Greek, Arabic, Hebrew, Devanagari, Thai, Japanese,
Chinese, and mixed text. Cover combining marks, grapheme clusters, ZWJ emoji,
and missing glyphs. Check actual HarfBuzz output and rendered pixels, not only
font names. Exercise cache corruption, font changes, and missing libraries.

Run relevant Ghostty and Play tests, real Laputa package proofs, ELF provider
audits, and Tinyland guest qualification. Preserve keyboard, presentation,
screenshot, compositor recovery, and existing security gates. Report cross
builds separately from native execution and guest passes.

### Remove only unused dependencies

After both consumers pass, remove `libfontconfig.so.1`, its package dependency,
and unused Fontconfig configuration from the canonical graphical root. Remove
Expat only if the complete root has no remaining consumer. Retain independently
useful Expat packaging elsewhere.

Audit direct and transitive ELF edges and runtime-loaded libraries. Update
consumer audits, Laputa provider proofs, and build and release documentation.
Absence of a direct import alone does not prove closure removal.

### Measure before promotion

Compare stripped production products in actual composed Laputa roots. Count
unique files across Ghostty and Play once. Report library size, transitive
font closure, combined application closure, index bytes, cold discovery, warm
startup, typical and multilingual queries, RSS, and shared and private memory.

Compare optional feature configurations only when they address a measured cost.
Use verified LTO and size settings without sacrificing ABI or rendering
correctness. Interleave timing samples and apply host readiness checks before
and after accepted windows. Do not infer a size reduction from language choice.

Promotion requires both applications to use one independently packaged library,
correct international discovery and fallback, an audited ABI and closure, and
acceptable measured costs. FreeType and HarfBuzz remain shared. Native
Fontconfig and Expat must be absent from the canonical graphical font stack.

The completion report names repository commits, upstream pin, SONAME, feature
configuration, verification commands and results, installed footprint, measured
tradeoffs, and any genuinely unavailable production qualification. Never claim
an unpublished release or unexecuted guest pass.

## Upstream evaluation

Evaluated on 2026-11-04 against [fschutt/rust-fontconfig](https://github.com/fschutt/rust-fontconfig).
Everything below was observed at the pinned revision unless marked unmeasured.

### Pin

- Release `v5.0.2`, commit `966dc9c8187601ec4ad206a095a5f48fbe490279`
  (2026-10-29); crates.io and the GitHub release were published 2026-10-28.
  The tag is lightweight and unsigned. It is the latest release and the
  default branch head.
- Source: the GitHub tag archive, sha256
  `63f533566b8bcba902a8005f6f5408a6c62cbe8b979da2bcbca4090a33b38a7b`; its
  tree equals a clone of the tag. The crates.io `.crate` (sha256
  `ed5799956a5fa7abd968823c4d4876f2eb9301d5c02e2f53d0dc9471c001c782`) has the
  same version.
- Upstream commits no `Cargo.lock`. Laputa pins
  `packages/rust-fontconfig/files/Cargo.lock`, generated against crates.io
  with all optional features (69 crates, 14,193,845 bytes of `.crate` files,
  all vendored by PM). The `ffi` closure is 43 crates including 6
  proc-macro or macro-support crates.
- Upstream tests at the pin: with `--no-default-features --features ffi`, the
  library tests (33 pass, 1 ignored) and the integration tests `tests`,
  `issue_26_unicode_fallback_ranking`, and `registry_completion` (21, 10, and
  4 pass) pass on x86_64-linux-musl. `cargo test --features ffi` alone does
  not compile because the `registry` example needs `cache`; the
  `disk_cache_persistence` test needs `cache` and was not run.

### Maintenance and license

- One maintainer wrote 213 of the 237 commits since February 2021 (under
  three author spellings); 12 more are an automated "PR Analysis" account. There were 137 commits in 2026: 34
  in August, 14 in September, and 4 in October. Releases: 5.0.0 on
  2026-09-03 (breaking: fallback chains and `resolve_char` changed, disk
  manifest v3, `PatternMatch` discriminants pinned to the C header), 5.0.1 on
  2026-10-06, 5.0.2 on 2026-10-28. Four issues are open, including #29
  (the desktop's configured font passed in from outside) and #24
  (libfontconfig compatibility).
- The crate is MIT. The `ffi` closure is permissive: MIT, Apache-2.0, 0BSD,
  Zlib, BSD-3-Clause (`brotli-decompressor`, `alloc-no-stdlib`,
  `alloc-stdlib`, `glyph-names`, `encoding_rs` in part), Unicode-3.0
  (`unicode-ident`). `allsorts-azul` (Apache-2.0) is the font parser. No
  GPL or LGPL crate is in the closure. PM installs the upstream `LICENSE`
  only; third-party notices for the statically linked crates are not
  installed.
- Release cadence is high and 5.0.0 changed behavior and the manifest
  format, so each bump needs a re-run of the package proof and a decision on
  the SONAME (below).

### Feature graph

`std` always on (`mmapio`); `parsing = [allsorts-azul, xmlparser, std]`;
`async-registry = [std, parsing]`; `ffi = [parsing, std, async-registry]`;
`multithreading = [rayon]`; `cache = [serde, bincode, dirs, std]`.

- `ffi` enables the async registry and the only font parser. It does not
  enable `multithreading` or `cache`.
- XML parsing has no feature of its own: `xmlparser` (pure Rust, no
  features) comes with `parsing`, so separating it from metadata parsing
  needs an upstream change. Its share of the library size is unmeasured.
- `cache` is unreachable from C: no export loads or saves a disk cache.
  `multithreading` is reachable through `fc_cache_build`.
- Selected: `--no-default-features --features ffi`.

Measured with a stripped `cdylib` on x86_64-linux-musl (PM payload bytes,
fat LTO, one codegen unit unless noted):

| Configuration | Library bytes |
|---|---:|
| `ffi`, release defaults | 1,480,336 |
| `ffi`, LTO, `opt-level=3` | 1,258,664 |
| `ffi`, LTO, `opt-level=s` (selected) | 1,111,248 |
| `ffi,multithreading`, LTO, `opt-level=3` | 1,328,928 |
| `ffi,cache`, LTO, `opt-level=3` | 1,291,712 |

`fc_cache_build` over the 9 font files (18 faces, 31.6 MB) of the proof set,
15 interleaved runs on the busy build host (median CPU ms, median RSS kB):
`ffi` `opt-level=3` 2.3 and 3,076; `ffi` `opt-level=s` 2.3 and 2,896;
`ffi,multithreading` 10.3 (3.1 wall) and 3,792. Over 81 faces (those plus the
host's `/usr/share/fonts`): 7.7, 8.1, and 84.5 CPU ms (10.1 wall) respectively.
`multithreading` costs more CPU and wall time at these counts and is left
off. Timings used no perf-gate window (`perf-gate-ready` reported a hot
process tree); read them as relative.
Package build time was 46 to 51 s wall at `-j 8` under load, for every
configuration.

### C interface

- 52 exports, all `fc_*`. They equal the 52 functions `ffi/rust_fontconfig.h`
  declares, and the 12 `#[repr(C)]` structs match the header's field names and
  order. The package proof asserts the export set equals the header's set.
- Every export runs in `catch_unwind` and returns null, false, or zero on a
  panic. That requires `panic=unwind`; the recipe omits the `panic=abort` used
  by the other Rust packages. The panic path itself is untested.
- Returned objects have matching `*_free` functions. The proof exercises
  them; no sanitizer or concurrent-use test has run.
- There is no version function or macro, no `fc_*` entry to set scan
  directories or an `FcFallbackConfig`, and no disk-cache entry.
- On Linux `fc_cache_build` and the registry read `$FONTCONFIG_FILE` or
  `/etc/fonts/fonts.conf` for `<dir>` entries and `<alias>` preferences. With
  that file missing, or without `<dir>` entries, they scan **no fonts**; the
  built-in directory list serves only the filename-only (non-`parsing`)
  scan. Removing the Fontconfig package's `fonts.conf` therefore needs
  either a Laputa-owned file or an upstream injection API.
- `fc_resolve_font_chain` and `fc_registry_request_fonts` pass no script
  hint, so a chain precomputes only the default blocks: Cyrillic, Arabic,
  Devanagari, Hiragana, Katakana, CJK Unified Ideographs, and Hangul. With
  all fonts installed, a `["Hack", "monospace"]` chain resolved Latin to Hack,
  U+0633 to DejaVu Sans, U+0915 to Noto Sans Devanagari, and U+4E2D to
  Noto Sans CJK, but returned no font for U+0E01 (Thai) and U+1F600 (emoji).
  A coverage query (`fc_pattern_add_unicode_range` then `fc_cache_query`)
  found Noto Sans Thai, Noto Color Emoji, and DejaVu Sans (U+05D0) correctly.
  The Rust API has `resolve_font_chain_with_scripts`; the C API does not.
  Hebrew and Greek through a chain were not tested.

### Package decisions

- **SONAME.** `librust_fontconfig.so.<upstream version>`, here
  `librust_fontconfig.so.5.0.2`. Upstream documents no ABI promise and ships
  no version symbol, so each upstream release is a new SONAME. The package
  proof fails if the SONAME is not the recipe version, if an export is not in
  the installed header, or if a header function is not exported; relaxing the
  policy to a shared major SONAME requires a recorded ABI comparison.
  The unversioned `librust_fontconfig.so` links to it for development.
- **Headers.** `usr/include/rust-fontconfig/rust_fontconfig.h` and
  `rust-fontconfig.pc` (`-I${includedir}`), because the header defines
  `FcPattern`, `FcFontCache`, and other names that C Fontconfig also uses and
  the two headers cannot share a translation unit.
- **Closure.** Runtime `DT_NEEDED` is `libc.so` only; no `RPATH`,
  `RUNPATH`, `libgcc_s`, Fontconfig, or Expat; the recipe adds no
  `gnu-stubs` edge.
- **Profile.** Fat LTO, one codegen unit, `opt-level=s`, unwinding panics, and
  the `-static-libgcc` link argument the other Rust recipes use.

## Alternatives considered

Retain C Fontconfig indefinitely. This preserves the baseline but does not meet
the owner's chosen replacement objective.

Reimplement its ABI or matching engine. This creates a second implementation
authority and unnecessary maintenance. Adapt consumers to upstream instead.

Link the Rust crate statically in each application. This duplicates code and
caches behind separate application ownership. The distribution owns one shared
library and its version policy.

## Open questions

The pinned upstream evaluation must settle configuration injection, cache
validation and generation compatibility, FFI ownership and panic behavior,
feature costs, and the supported ABI policy. These are implementation findings,
not reasons to replace upstream's engine.

## Prerequisite status

Recorded on 2026-11-04; the owner then authorized the upstream evaluation.

- **Shared native font stack:** qualified on x86_64 in
  [the font contract](../FONT-STACK.md): package proofs, the composed-root
  closure audit, Ghostty's font tests in the composed runtime (206 pass, 13
  skip, zero fail), and the graphical startup and idle-memory pairs. aarch64
  stays deferred with the rest of the campaign. Laputa's production Ghostty
  package still pins the published bundled build `f2024d5d2`.
- **Play SubRip migration:** Play `83070cc`, the source of release 0.42.2,
  passes its full Linux suite in its pinned container: 362 passed, zero
  failed, including SubRip loading, the native OSD and OSC, and gpu-next
  rendering on lavapipe.
- **Play Core Text migration:** macOS-only and outside this Linux campaign.
  Play's 0.42.2 release workflow built and checked the macOS app in CI; no
  owner-run macOS qualification is recorded here.

## Decision

The owner authorized this campaign after the shared native stack and Play
migrations. Record it before LAP-51. Start implementation only after those
prerequisites pass, and retain the working native baseline until both consumers
qualify. This document records no adoption or test success.

The owner's later scope correction retains `ffmpeg-build`, musl, and Linux.
FFmpeg/codec replacement, crabc evaluation or adoption, and allocator work are
outside this campaign. Subtitle and typography work remain separate consumer
requirements. No broader replacement is a prerequisite for discovery adoption.
