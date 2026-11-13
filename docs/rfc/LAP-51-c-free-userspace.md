# LAP-51: Reduce native dependencies in the owned desktop

Status: draft

## Summary

Build a Rust/XSH/Zig-owned desktop and system layer with maintained exceptions
for FFmpeg, graphics enablement, musl, and Linux. Target actual remaining
implementation dependencies while preserving a usable accelerated system.
A C calling convention does not require C implementation code.

Complete the shared native font stack and Play's SRT/native-text migrations,
then execute [LAP-52](LAP-52-rust-fontconfig.md). The broader tracks below
follow that qualified discovery baseline. Preserve native Core Text on macOS.
The current campaign executes on Linux only.

FFmpeg and codec replacement are explicitly out of scope. Keep `ffmpeg-build`
as the maintained native media dependency without changing its internal
compression libraries or decoder choices. Play's subtitles, typography, OSD,
and application-layer work remain in scope.

Musl and Linux remain intentional dependencies. Their replacement, crabc
adoption or evaluation, allocator work, and GPU-driver rewrites are explicitly
out of scope. Keep the existing Asterinas/Linux-ABI qualification separate.
Bare-metal enablement, Wi-Fi, Bluetooth, physical graphics and audio, and
laptop power management remain deferred.

## Motivation

Independent shared libraries establish distribution ownership and permit
application deduplication. The [font contract](../FONT-STACK.md) provides that
boundary for Ghostty and prospective Play integration. Keep native text
implementations as differential baselines while replacements earn promotion.
Do not restart working migrations or introduce private static copies.

The current sources already establish several foundations:

| Area | Existing implementation | Remaining boundary |
|---|---|---|
| SSH | XSH vendors OxiSH with Graviola, and xinfra consumes its native client. | Laputa consumes the ssh-build `oxish` archive: its login-mode server replaces Dropbear for login, PTY and SFTP/scp, and `oxish-sftp`/`oxish-scp` are the transfer clients. |
| Keyboard | Tinyland uses KBVM. xkbcommon belongs to the optional oracle feature. | Audit remaining consumers and preserve keymaps, compose, modifiers, and text input. |
| Seat management | The Rust seatd daemon is packaged with a C libseat client. | Qualify a seatd-only Rust client for Tinyland before removing the C provider. |
| Device management | mdevd-rs calls libc POSIX regex functions for matching and captures. | Preserve capture byte offsets, syntax, locale behavior, and errors in a separate compatibility effort. |
| XSH compression | xsh-archive selects zlib-rs. Its bzip2 0.6.1 dependency defaults to the Rust backend. | Distribution `libz.so.1` replacement and other native compression consumers need separate qualification. |

These are source findings, not new runtime passes. Tinyland's manifest does
not request Wayland system backends, but resolved features and ELF evidence
must establish its actual closure. A Rust daemon may still call musl, and an
executable without dynamic imports may contain statically incorporated C.

## Design

### Establish the actual closure

Extend the PM provider audit and existing consumer audits. Avoid a second
package database. For each identified profile and application build, count
unique installed files and bytes, direct and transitive SONAMEs, runtime-loaded
modules, and statically incorporated native code. Distinguish build-only tools,
package-declaration-only edges, and unknown source attribution.

Include Ghostty and Play without counting shared files twice. Play is not yet
a qualified Laputa package. Its current Linux target is x86_64 musl; adding
an aarch64 Play target is separate work. Treat `ffmpeg-build` as a maintained
exception and measure its installed contribution without replacing its codecs.

Audit the `wayland-libs-client` Expat edge against actual runtime and scanner
use. Remove Expat from a root only when no consumer remains. Its current
Fontconfig use persists until LAP-52 passes.

### Track A: finish the selected text architecture

The order is shared native FreeType/HarfBuzz/Fontconfig, Play SRT/native text,
shared rust-fontconfig, HarfRust, then a qualified FreeType replacement.
LAP-52 owns discovery adoption. Both applications must dynamically consume the
same distribution-owned upstream library. Keep shaping, bidi, line breaking,
rasterization, and composition with their respective owners.

Measure the combined application and font closure. Retain the known-working
native text stack for comparisons and preserve modular font coverage packs.
Correct shaping and installed glyph availability remain separate guarantees.

### Track B: finish small desktop interfaces

Prioritize a seatd-only Rust client for Tinyland. Preserve broker admission,
device-FD ownership, session enable and disable, disconnect handling, and
fail-closed behavior. Add a compatibility C ABI only for an actual consumer.
Do not expand this into every libseat backend.

Extend existing KBVM adoption to remaining consumers only after keymap,
compose, modifiers, and text-input tests pass. A narrow Rust C interface can
serve a Zig consumer without creating a C implementation dependency.

Audit each Wayland consumer's protocol backend and EGL/Vulkan integration.
Do not disable system features indiscriminately or equate protocol replacement
with removing libwayland from the complete graphics closure. Tinyland remains
the compositor; introduce no larger framework for language-count purposes.

Handle mdevd's POSIX regex boundary separately, using the existing matcher as
the oracle for matching, capture extraction, byte offsets, locale, and errors.
It has lower urgency while musl remains intentional.

### Track C: qualify distribution compression providers

Evaluate [zlib-rs](https://github.com/trifectatechfoundation/zlib-rs) as an
independent `libz.so.1` provider. Verify the exported interface, streaming,
allocators, gzip behavior, checksums, errors, and actual consumers on both
musl architectures. XSH already uses the Rust backend; do not launch a
redundant XSH migration. This track must not change `ffmpeg-build` or any
internal FFmpeg dependency.

Audit the existing bzip2 Rust closure and remaining native consumers before
proposing a distribution provider change. Trace the roles of xsh-archive's
native liblzma, lzma-rust2, and zstd paths against actual operations and tests.
The current XZ decoder uses native liblzma; a manifest alone does not establish
that another backend can replace it.

Keep [libzstd-rs-sys](https://github.com/trifectatechfoundation/libzstd-rs-sys)
experimental. Upstream describes a decoder for experimental use and an encoder
still dominated by an unsafe translated implementation. Do not equate Rust
source with demonstrated safety, compatibility, or maintenance benefit.

### Track D: qualify the next text backend

Evaluate [HarfRust](https://github.com/harfbuzz/harfrust) against the actual
Ghostty and Play shaping workloads. Its integration differs from HarfBuzz,
including the FreeType/Core Text interfaces. Adapt and test consumers rather
than claiming drop-in ABI compatibility or adopting upstream performance
percentages as predictions.

Use [HarfBuzz's HarfRust shaper testing route](https://github.com/harfbuzz/harfrust/blob/main/HARFBUZZ.md)
for differential tests and benchmarks. That arrangement retains HarfBuzz and
therefore does not itself remove the C++ library.

Evaluate Swash as an integration layer over Skrifa and Zeno. The
[current Swash manifest](https://github.com/dfrg/swash/blob/main/Cargo.toml)
uses Skrifa and enables Zeno for rendering. These are related components,
not unrelated competing stacks. [Skrifa](https://github.com/googlefonts/fontations/blob/main/skrifa/README.md)
provides font metadata and hinted outlines, with documented Chrome use and
FreeType comparisons. Pixels still require rasterization and composition.
[Zeno](https://github.com/dfrg/zeno) supplies path masks suitable for evaluating
against the existing glyph-bitmap architecture.

The proposed pipeline is rust-fontconfig discovery, HarfRust shaping,
Swash/Skrifa/Zeno rasterization, and existing application glyph caching and
composition. It is not a qualified Laputa stack. Exercise fallback boundaries,
combining sequences, complex scripts, ZWJ emoji, color and bitmap fonts,
variable axes, scaling, metrics, and cache ownership through final pixels.
Require representative correctness and performance before replacing FreeType.
Keep one distribution implementation rather than private application stacks.

### Track E: preserve runtime and kernel independence

Retain musl and Linux. Crabc remains heavy work in progress and is explicitly
excluded from evaluation, adoption, or prerequisite planning in this roadmap.
Do not resume its frozen allocator work. Retain the existing Asterinas
qualification as a separate track with its own pinned sources and evidence.
A pass on one kernel does not qualify another.

### Keep lower-confidence projects bounded

Crabtables is adopted as the firewall: the `crabtables` package ships `nfcrt` and
replaces the C nftables, libnftnl and libmnl packages. Qualification must keep
preserving atomic failure, packet verdicts, permissions, recovery, and
host-firewall isolation in disposable namespaces (the maintained-guest firewall
drills). Project-provided benchmarks do not establish operational maturity.
Fixes land in laputa-systems/crabtables first, and the recipe pins the commit.

Do not put e2fsprogs replacement on the production roadmap. rust-fs-ext4's
partial checker can inform disposable-image access, limited formatting, or
research, subject to independent feature and crash qualification.

A later VM-only PCM experiment may examine direct ALSA kernel access. It does
not establish full device configuration, controls, or arbitrary-hardware audio.
Physical audio and wireless work remain deferred.

Retain narrowly configured Mesa and graphics enablement. Rusticl's OpenCL
implementation does not replace that closure. Zeno, tiny-skia, resvg, and
moxcms are possible tools for real future mask, drawing, SVG, or ICC consumers;
they are not automatic dependencies or a reason to add absent capabilities.

### Require evidence for promotion

Each selected pilot needs pinned, offline reproducible inputs, explicit APIs
and features, differential tests, and appropriate independent review. Preserve
existing security and guest gates. Check errors and hostile inputs at relevant
boundaries. Remove an old provider only after every runtime consumer qualifies.

Measure unique installed closure, build cost, startup, CPU, and memory against
production settings. Interleave at least five samples for timing claims and
apply readiness checks before and immediately after accepted windows. No
language choice alone establishes a size or performance improvement.

Every candidate below carries the same four gate classes, defined in
[Native census](../NATIVE-CENSUS.md#replacement-gates) and inherited here by
reference: differential correctness against the C library as oracle through the
real consumer, identical failure classes on hostile and boundary inputs, closure
that removes the SONAME and adds nothing, and interleaved performance with
readiness checks. The census records the per-candidate oracle, corpus, failure
set, closure target, and workload. Defining a gate is not running it: no gate
has been executed and no production default changes.

| Candidate | Correctness oracle | Failure set | Closure proof | Performance workload |
|---|---|---|---|---|
| seatd client (`libseat.so.1`) | C client against the Rust daemon | disconnect, denied open, `EINTR`, FD exhaustion, fail closed | tinyland `DT_NEEDED` becomes `libc.so` alone | seat-open latency, tinyland guest startup |
| libxkbcommon | Ghostty's `xkb_*` import list; every keycode, modifier, group | malformed keymap, missing XKB directory | `libxkbcommon.so.0` leaves; `xkeyboard-config` kept or replaced | keymap compile, per-key cost |
| zlib (`libz.so.1`) | C oracle inflate at every level, round-trip, gzip, streaming | truncated, corrupt, bomb; allocator hooks | identical exported symbol set | `compress2` on RGBA, PCF inflate |
| FreeType, HarfBuzz, libpng | final pixels: fallback, combining, ZWJ, color, variable axes, Arabic | FreeType fuzz corpus, malformed fonts | all three SONAMEs leave together | 100,000-iteration Arabic shape and rasterize; memory pairs |
| Wayland client library | ABI for Mesa, Ghostty, Play | malformed protocol, disconnect | SONAME leaves only after all three qualify | startup and idle RSS |
| Prebuilt-release statics | output equivalence: regex matches, shader validation, rendered frames | malformed shaders and images | per-component share shrinks in the unstripped baseline | render workload per component |

## Alternatives considered

Rewrite every native dependency. This forces unrelated media, runtime, kernel,
and hardware projects into desktop work and conflicts with the owner's scope.
Maintain those explicit exceptions instead.

Replace libraries privately per application. That duplicates ownership and
code. Preserve independently versioned distribution libraries and migrate
consumers together where an interface changes.

Collect Rust equivalents without consumers. That adds capabilities and
maintenance without removing existing machinery. Select work from actual
closure and consumer evidence.

## Open questions

The census must establish remaining consumers, static code, and unknown
attribution. Each admitted replacement must establish maintenance, licenses,
ABI coverage, musl behavior, quality, and costs. No candidate is qualified by
this document, and no FFmpeg build qualification is claimed.

## Decision

Apply the owner's 2026-11-04 corrections. Prioritize existing text and desktop
infrastructure, distribution compression, and later text backend qualification.
Exclude FFmpeg/codec replacement, musl/Linux replacement, crabc, allocator work,
and GPU-driver rewrites. Keep deferred hardware outside the immediate queue.
This draft launches no new pilot and does not waive the active campaign's
acceptance requirements.
