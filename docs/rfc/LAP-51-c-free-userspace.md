# LAP-51: Toward a C-free Laputa userspace

Status: draft

## Summary

Pursue a usable, accelerated Linux distribution whose services and applications
use predominantly Rust or Zig, with orchestration policy in XSH. Isolate the
remaining C/C++ implementation dependencies behind documented interfaces.
Keep Linux and musl while replacements earn adoption through actual consumer
tests. Start this work after the active campaign and the
[rust-fontconfig adoption](LAP-52-rust-fontconfig.md).

Distinguish three milestones:

1. Services and utilities implemented without C/C++.
2. Desktop infrastructure with a progressively smaller C/C++ closure.
3. Whole-system research covering the kernel, libc, drivers, and toolchain.

The first two milestones do not require the third. An accelerated profile
retains narrowly configured Mesa while a separate software-rendered profile
can explore further dependency removal. Software rendering does not establish
equivalent acceleration, video performance, or hardware support.

## Motivation

Independent shared libraries let multiple applications use one distribution
implementation. The [font stack](../FONT-STACK.md) provides that boundary for
Ghostty and future Play integration. Retaining a C ABI does not require a C
implementation. Replacing a shared implementation must preserve the ABI or
explicitly migrate every affected consumer.

The local Play checkout already uses the standard Fontconfig, HarfBuzz, and
FreeType APIs for Linux text. Its dependency builder statically incorporates
zlib, dav1d, shader tools, and libplacebo. Its runtime audit also admits Vulkan,
Wayland, ALSA, VA-API, musl, and libgcc. Play is a prospective Laputa consumer,
not a currently qualified Laputa package. Its existing Linux target is x86_64
musl. Adding an aarch64 Play target is separate work.

Tinyland already selects KBVM and leaves xkbcommon behind its optional oracle
feature. Its manifest does not request Wayland's system-backend features.
Verify resolved features and the actual ELF before crediting any removal.
Removing a C library from Tinyland does not remove Ghostty's or Mesa's use of it.

## Design

### Establish the actual closure

Extend the existing PM ELF provider audit and application audits. Avoid a second
dependency database. For each identified build and profile, account for:

- Unique installed files and bytes, including resources and font files.
- Direct and transitive SONAMEs, loader paths, and runtime-loaded modules.
- C/C++ and assembly incorporated statically, using build inputs and link evidence.
- Runtime dependencies retained solely by package declarations.
- Host and target build tools excluded from runtime roots.
- Unknown attribution, recorded explicitly rather than counted as Rust.

ELF imports cannot identify all source languages. A static executable can still
contain C, and a Rust binary can retain musl. Use the built products and their
build graph together. Do not infer a security improvement solely from language
or count the same shared file once per application.

Audit `wayland-libs-client`'s Expat declaration against its ELF and scanner
build. Expat remains required by the current Fontconfig package, so deleting
one dependency edge alone need not shrink the graphical closure.

### Qualify compatible replacements first

After LAP-52, the initial ordering is a census, a zlib-rs pilot, then independent
firewall and media pilots. LAP-52 first qualifies shared rust-fontconfig for
Ghostty and Play after the native font stack and Play migrations. Remaining
font replacement follows that baseline. Candidate capabilities below are upstream claims or documented APIs,
not Laputa qualification results.

| Candidate | Proposed experiment | Required boundary |
|---|---|---|
| [zlib-rs](https://github.com/trifectatechfoundation/zlib-rs) | Build its shared C interface as a candidate `libz.so.1` provider. | Verify exported symbols, stream state, allocators, gzip behavior, checksums, errors, and actual consumers on both musl architectures. |
| [crabtables](https://github.com/finnbear/crabtables) | Compare Laputa's actual firewall policy through direct netlink or `nfcrt` in disposable namespaces. | Check atomic failure, rollback, sets, counters, packet verdicts, permissions, and service recovery. Keep the host firewall untouched. |
| [rav1d](https://github.com/memorysafety/rav1d) | Substitute the AV1 decoder in Play's pinned FFmpeg build. | Compare decoded frames, bit depths, malformed input, seek/flush, CPU, memory, and complete playback. Retain the existing decoder until qualified. |
| [wayland-rs](https://github.com/Smithay/wayland-rs/tree/master/wayland-backend) and [KBVM](https://github.com/mahkoh/kbvm) | Audit remaining native protocol and keyboard consumers. | Preserve object identity, FD passing, input behavior, EGL/Vulkan integration, and broker security. |
| [rust-fontconfig](https://github.com/fschutt/rust-fontconfig) | Complete [LAP-52](LAP-52-rust-fontconfig.md) before this roadmap begins. | Both consumers use one shared upstream library. Its C interface requires consumer adaptation rather than reproduction of the `Fc*` ABI. |
| [HarfRust](https://github.com/harfbuzz/harfrust/tree/main/harfrust_capi) | Differential shaping with the installed international corpus. | Its C interface uses `hr_*`; compatibility headers provide source adaptation. Verify every consumer API, including Ghostty's FreeType integration, before replacing `libharfbuzz.so.0`. |
| [Swash](https://github.com/dfrg/swash) | Compare rasterization, hinting, metrics, variations, and color glyphs. | A Rust font API does not establish FreeType ABI compatibility. Preserve glyph quality and application behavior. |
| [rust-fs-ext4](https://github.com/antimatter-studios/rust-fs-ext4) | Compare formatting and checking disposable images against e2fsprogs and Linux. | Upstream describes its checker as a subset of e2fsck. Qualify supported features and crash recovery before using it for repair. |

Do not replace the font stack by statically embedding a second private stack in
each application. A replacement may provide a verified compatible library or
an explicitly versioned distribution-owned interface with coordinated consumer
migrations. Never put incompatible code behind an established SONAME.

### Keep difficult boundaries explicit

Retain Dropbear until an SSH server candidate meets the existing authentication,
session, recovery, and remote-maintenance requirements. OxiSH is a tracking
candidate, not an approved server replacement.

Treat direct ALSA output and a Rust wireless supplicant as separate research.
Audio needs device negotiation, underrun recovery, channel mapping, and device
changes. Wireless needs protocol and hostile-input qualification beyond one
successful handshake. Real-hardware enablement remains deferred under the
current campaign's scope.

Retain Mesa for the accelerated profile. Rusticl's OpenCL role does not replace
the graphics driver closure. Evaluate broader codec projects only after the
narrow AV1 experiment. Keep relibc and Asterinas as separate compatibility
research rather than prerequisites for service or desktop migration.

### Require evidence for promotion

Each pilot uses pinned inputs and offline reproducible builds, a precise API
and feature inventory, differential tests, and independent review. Exercise
failures and hostile inputs where relevant. Preserve existing security gates.
Measure build cost, installed closure, startup, CPU, and memory against the
production configuration. Interleave at least five samples for timing claims
and apply host-readiness checks before and after each accepted window.

Adopt one candidate at a time only after its actual Laputa consumers pass.
Remove an old provider only when no remaining consumer needs it. Keep font
files modular and distinguish shaping capability from installed glyph coverage.
Do not adopt upstream benchmark percentages as Laputa results.

## Alternatives considered

Keep every existing implementation indefinitely. This avoids migration risk
but misses opportunities to reduce parsing exposure and duplicated native code.

Rewrite every dependency immediately. This makes the distribution depend on
unqualified replacements and ties useful progress to Mesa, libc, and hardware
research. The staged approach retains a working accelerated system.

Replace libraries privately in individual applications. This can demonstrate
an API experiment, but it defeats distribution deduplication and does not
satisfy the shared font contract.

## Open questions

The census must establish the actual runtime consumers and static native code.
Each pilot must establish maintenance quality, ABI coverage, licenses,
transitive dependencies, musl behavior, and measured costs before adoption.
No replacement candidate has been qualified by this document.

## Decision

Record the owner's long-term direction and the proposed qualification order.
LAP-51 is planned follow-on work. This draft does not launch replacement pilots,
change production defaults, resume hardware work, or replace the current
campaign's acceptance requirements.
