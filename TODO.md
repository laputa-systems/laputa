Prefix: LAP
Next: 78

Open work from package-manager development, the local bootstrap, and the
XSH/Laputa systems-foundation review. Priorities are assumed from impact;
verification gaps are marked unproven. [Roadmap](docs/ROADMAP.md) owns direction
and milestone sequencing; this file owns bounded implementation slices.

Apply the roadmap's design filter: keep policy in ordinary XSH, reuse narrow
host operations, and remove duplicated responsibilities rather than growing
parallel managers or frameworks. [XSH's queue](https://github.com/laputa-systems/xsh/blob/master/TODO.md)
owns shared substrate changes; peer IDs below identify coordination, not authority
to modify another checkout. Owning topic documents record qualified behavior
and its remaining limits.

Real-hardware enablement remains out of scope. Existing hardware entries are
retained but deferred as noted below. aarch64 qualification is deferred
pending a macOS aarch64 host via Docker; no Linux aarch64 hardware is
available in this campaign. VM clocks, virtual networking, disposable
disks and native build hosts remain in scope. Existing paused campaigns are not resumed. The current Laputa campaign covers
runnable entries using the supplied fixed XSH snapshot. External XSH repairs
and real-hardware enablement remain outside that scope.

The current owner-directed campaign includes Linux performance qualification.
Timing measurements require quiet-host readiness checks before and after each
accepted window. macOS remains out of scope. Native aarch64 runtime
qualification remains open; manual cross-build evidence is bounded in
[the font contract](docs/FONT-STACK.md).

### LAP-6 · P2 · Boot the aarch64 world in a guest

- **Area:** Tests
- **Where:** `docs/TESTING.md:45`, `system/qemu.xsh`, `docs/QEMU.md`
- **Problem:** The completed x86_64 bootstrap changed shared PM, musl, headers, installer and profile paths. The aarch64 world now builds clean: on 2026-11-20 `make build ARCH=aarch64` on m1-max (OrbStack, linux/arm64) against the published aarch64 images produced all 87 artifacts and passed every package proof, after the libcap proof skipped its loader-started check on aarch64 (`ab7b6cde`; musl's loader SIGBUSes starting an executable shared object with a C entry) and the arm64 Kbuild plan stopped carrying the EFI stub objects its final link builds (`cf2bb1b1`). No aarch64 guest has booted that world, so the installer and profile paths are unproven there.
- **Recommendation:** Boot the aarch64 world's installer and profile proofs in an aarch64 guest with hardware acceleration (KVM on Linux aarch64, or HVF on macOS aarch64, which `system/qemu.xsh` supports) and fix what fails. Acceptance: the installer and profile proofs pass on aarch64.
- **Fix with:** root-cause
- **Effort:** M

### LAP-47 · P2 · Complete ntpd-rs qualification and clock bootstrap policy

- **Area:** Time discipline
- **Where:** `ntpd-rs/`, imported from the `laputa-systems/ntpd-rs` fork at `910ecd0`, `2.0.0-alpha.20260715`
- **Problem:** aarch64 runtime qualification of the maintained NTS clock remains unproven; the x86_64 profile is qualified (see Progress). The aarch64 package builds and passes its package proof (m1-max, 2026-11-20); only the guest cases remain.
- **Recommendation:** Qualify the remaining cases in disposable guests before enabling an authenticated production configuration. Never alter the host clock. Cold boot requires trustworthy RTC or operator-set time; preserve TLS and snapshot expiry verification.
- **Fix with:** reference-parity
- **Effort:** M
### LAP-63 · P2 · Measure representative package and system journeys

- **Area:** Performance
- **Where:** `docs/TESTING.md` Benchmarks
- **Problem:** Plan time, warm rebuild reuse and root composition now have checked, timed Scenario workloads (`world-plan`, `warm-rebuild`, `root-compose` in `bench/registry.xsh`), but no accepted timing anchor: every run on the shared build host so far is `inconclusive: host busy`. Mirror publish, boot to a usable system and xinit service start still lack a representative checked timing comparison.
- **Recommendation:** Add checked timed workloads for mirror publish (bytes and artifacts verified), profile boot to a readiness marker, and xinit service start, following the same five-round readiness-bracketed pattern; then capture `-ns` anchors for all six on a quiet host with justified tolerances. Acceptance: each journey has a reproducible comparison and a quiet-host anchor, and reports inconclusive samples explicitly.
- **Fix with:** bench-pyramid, benchmark-checklist
- **Effort:** L
### LAP-64 · P2 · Capture memory and artifact size anchors

- **Area:** Performance
- **Where:** `bench/anchors.tsv`, `bench/capture.sh`, `docs/TESTING.md` Benchmarks
- **Problem:** `make bench TIER=scenario WORKLOADS='tree-memory artifact-sizes'` measures the package-tools container's cgroup `memory.peak` for an offline `baselayout` plan, and the bytes of the seed products, the newest `baselayout`, `musl` and `linux-headers` artifacts and the package-tools image. Each result records commit, dirty state, artifact hashes and host readiness, and reports within budget, regression or inconclusive. `bench/anchors.tsv` is empty: on 2026-11-20 the shared host was busy, so every verdict is `inconclusive: no anchor`. The installer ISO is excluded until it is built.
- **Recommendation:** On a quiet host, run `bench/capture.sh` as docs/TESTING.md describes and commit the anchors with their provenance. Acceptance: both workloads report within budget against committed anchors on a ready host.
- **Fix with:** bench-pyramid
- **Effort:** S
### LAP-16 · P3 · Exercise sound and wireless device support

- **Area:** Tests
- **Where:** `system/qemu.xsh:1`, `packages/linux/files/config/aarch64/base-aarch64.fragment:1879`
- **Problem:** The graphical proof covers neither sound nor wireless devices. WLAN is disabled in the kernel fragments, and QEMU does not exercise the installed audio tools.
- **Recommendation:** Choose a supported device path, enable its kernel support, and verify the matching userspace against it.
- **Fix with:** reference-parity
- **Effort:** M
- **Deferred:** Wireless and physical-device enablement are out of scope. Any separately selected virtio-audio proof must remain VM-only and must not enable physical drivers or firmware as a side effect. This item is not permission to widen hardware scope.

### LAP-17 · P3 · Check aarch64 perf event recording in a guest

- **Area:** Kernel
- **Where:** `packages/linux/files/config/aarch64/base-aarch64.fragment`
- **Problem:** The aarch64 kernel now enables PERF_EVENTS with the symbols upstream `olddefconfig` resolves for it (HW_PERF_EVENTS, ARM_PMU, ARM_PMUV3, ARM64_BRBE and the rest), and `packages/linux/check_config.xsh` reports no drift for either architecture. Recording has not been observed on an aarch64 guest.
- **Recommendation:** Boot the aarch64 profile on a native aarch64 KVM host and record a `perf` sample. Acceptance: `perf record` and `perf report` show samples from a workload in the guest.
- **Fix with:** reference-parity
- **Effort:** S
- **Blocked:** Needs an aarch64 Linux host with KVM (owner ruling 2026-11-20: aarch64 builds run on the m1-max Mac; guest proofs need such a host).
### LAP-20 · P3 · Fork the Rust toolchain build to retire gnu-stubs

- **Area:** Dependencies
- **Where:** `packages/gnu-stubs/PKGBUILD.xsh`, `packages/cargo/PKGBUILD.xsh`
- **Problem:** Laputa-built Rust packages no longer load libgcc_s.so.1: the cc wrapper links LLVM's static libunwind.a for `-static-libgcc`. Play 0.42.2 links its GCC runtime statically. One consumer still needs gnu-stubs at run time: the prebuilt upstream `cargo`, `rustc`, `rustdoc`, `rust-lld`, `rust-analyzer-proc-macro-srv` and `libstd-*.so` from static.rust-lang.org import `_Unwind_*` from libgcc_s.so.1, and Laputa cannot relink them. Builds also take gnu-stubs' empty crtbeginS.o and crtendS.o from cargo's closure.
- **Recommendation:** Fork the Rust toolchain build under laputa-systems and build cargo, rustc and the musl std from source against Laputa's musl with the `llvm-libunwind` std feature, so nothing imports libgcc_s. Retire libgcc_s.so.1 and the crt stubs once no recipe or prebuilt input needs them.
- **Fix with:** reference-parity, dead-code-archaeology
- **Effort:** L
- **Acceptance:** No package's installed ELF files carry a libgcc_s NEEDED entry or a GCC runtime import, the PM ELF check reports no gnu-stubs provider, and Rust packages still build and pass their proofs with the source-built toolchain.
- **Parked:** The prebuilt `cargo`, `rustdoc`, `librustc_driver`, `libstd`, `rust-lld` and helper tools import libgcc_s; `rustc` does not. A source-built `cargo` needs an OpenSSL-compatible TLS library for curl, libgit2 and libssh2, and Laputa ships none: the routes are curl's rustls backend (needs `rustls-ffi`, which the rust source does not vendor, and drops ssh git), AWS-LC through `openssl-sys`, or a `cargo` without network TLS. Each adds work or a native dependency the owner does not want now, so gnu-stubs stays. The prebuilt 1.99.0 works as stage0 and Laputa's LLVM 23.1.5 as the external LLVM. The cargo proof skips its runtime check when `libgcc_s.so.1` is absent, so it must become a real run once gnu-stubs leaves its closure.

### LAP-51 · P3 · Establish the native-code census and replacement gates

- **Area:** Dependencies
- **Where:** `pm/elfdeps.xsh`, `docs/FONT-STACK.md`, `profiles/qemu-tinyland-ghostty.xsh`, `packages/wayland-libs-client/PKGBUILD.xsh`, `../play/scripts/audit-linux.sh`
- **Problem:** The ELF provider closure identifies libraries but does not account for statically incorporated C/C++ or establish that a Rust replacement preserves consumer contracts. The graphical profile and Play need a common, measured starting point before replacing libraries.
- **Recommendation:** After the active campaign, Play's SRT/Core Text migrations, and LAP-52, extend existing PM and application audits into a per-profile census. Count unique installed files, static native code, runtime-loaded providers, and build-only inputs separately. Prioritize the seatd client, remaining keyboard/Wayland consumers, distribution zlib, and later HarfRust/Swash qualification. XSH already uses Rust zlib and bzip2 backends. Preserve the shared font contract throughout.
- **Fix with:** architect, reference-parity, benchmark-checklist
- **Effort:** M
- **Design:** [C-free userspace direction](docs/rfc/LAP-51-c-free-userspace.md)
- **Scope:** Retain `ffmpeg-build`, Mesa, musl, and Linux. FFmpeg/codec replacement, crabc evaluation or adoption, allocator work, and GPU-driver rewrites are explicitly excluded. The firewall is now `crabtables` (`nfcrt`); filesystem experiments are lower-confidence research; physical hardware stays deferred.
- **Acceptance:** Reproduce the census for the Tinyland/Ghostty profile and a separately identified Play build. Explain each native dependency and every unknown attribution. Establish differential correctness, failure, closure, and performance gates for each proposed replacement without changing production defaults.
- **Progress:** The census is a re-runnable check, `qualification/native-census/census.xsh`, and its findings and the replacement gates are in [Native census](docs/NATIVE-CENSUS.md). On the composed 11-root x86_64 profile it accounts for each graphical binary's `DT_NEEDED` providers and for the C and C++ linked statically into it:
  - **Ghostty:** twelve components plus Highway. Per-component symbol bytes come from a `-Dstrip=false` build of the pinned commit. Highway's 12 runtime symbols and 16 instantiated kernels total 6,716 bytes.
  - **Play v0.43.2:** libplacebo, shaderc, glslang, SPIRV-Tools, libstdc++ and libgcc. After the archive list was corrected to `libshaderc_combined.a`, 5,000,962 symbol bytes are attributed and 3,257 non-Rust bytes remain, all identified.
  - **Mesa:** lavapipe's static LLVM share is 22,663 symbols and 12,434,304 bytes.
  - **xsh:** mimalloc, zstd and liblzma (xz 5.8.4). GCC 9.4.0 is Rust's bundled musl sysroot.
  The census reports its open-attribution count and names each open entry, and its gates are proven live by negative runs: a removed provider, marker or `DT_NEEDED` entry each fails with exit 3. Every proposed replacement has differential correctness, failure, closure and performance gates defined; none has been run and no production default changed. The Mesa build now writes a libgallium link map: LLVM is 44,830,058 of 80,655,466 live input-section bytes, and llvm-toolchain's libc++/unwind is 416,944. The census reports 0 open attributions on the rebuilt root. No cmake dependent is left unrebuilt: dropbear, the last, was removed when OxiSH replaced it.

### LAP-52 · P3 · Share rust-fontconfig across Ghostty and Play

- **Area:** Dependencies
- **Where:** `packages/`, `docs/FONT-STACK.md`, `../ghostty/src/font/`, `../play/rust/player-overlay/src/text/linux.rs`
- **Problem:** The canonical graphical stack still relies on C Fontconfig and Expat. Upstream rust-fontconfig has not been qualified as a shared discovery provider for both consumers.
- **Recommendation:** After the shared native font stack and Play SRT/Core Text migrations pass, package pinned upstream rust-fontconfig as one versioned musl shared library. Adapt both consumers to its C API, retain shared FreeType and HarfBuzz, and qualify configuration, caching, fallback, rendered output, ABI, closure, and measured costs before removing the native provider.
- **Fix with:** architect, reference-parity, benchmark-checklist
- **Effort:** L
- **Design:** [Shared upstream rust-fontconfig](docs/rfc/LAP-52-rust-fontconfig.md)
- **Acceptance:** Both applications dynamically resolve the same Laputa library. International discovery and cluster-safe fallback pass real rendering and guest proofs. Native Fontconfig and unused Expat leave the canonical graphical closure. Preserve macOS and existing security gates. Report exact upstream and repository revisions, SONAME, features, results, and installed footprint.
- **Progress:** The package builds the laputa-systems fork tag `v5.0.2-laputa.2`, which adds `fc_chain_candidates_for_text`: fonts covering a whole cluster, ranked by declared OpenType script, with a color flag. Ghostty `c4f036c72` (`-Dfont-backend=rust_fontconfig_freetype`) and Play 0.43.2 both need `librust_fontconfig.so.5.0.2` and not `libfontconfig.so.1`; their package proofs assert it. `rust-fontconfig` owns `/etc/fonts/fonts.conf`, and the `fontconfig` package and Expat no longer belong to the canonical closure. The x86_64/KVM guest proof (`make profile-test`, 2026-11-09) passes keyboard input, presentation, the crash, broker-loss and scanner recoveries, the security gates, and named screenshots of Ghostty and Play whose Arabic, Devanagari, CJK and ZWJ emoji lines are checked for tofu by `system/text_pixels.xsh`; the profile forbids `fontconfig` and `expat`. The aarch64 Ghostty and Play runs are deferred with the rest of the campaign. The stale `qualification/ghostty-shared` candidate recipe is removed; nothing consumed it. The final canonical 11-root x86_64 generation, composed after rebuilding 35 plan nodes that the gluon migration and the LLVM seed move had invalidated, has 31 packages, 1,630 unique regular files, 335,939,380 bytes and 48 ELF files, against 32, 1,548, 336,210,344 and 49 at the `fe1912a` baseline ([Shared font stack](docs/FONT-STACK.md#final-composed-root)). It has no `fontconfig` or `expat` package and no ELF needs `libfontconfig.so.1` or `libexpat.so.1`; the `rust-fontconfig`, `ghostty-custom` and `play` proofs pass. On the six-font package-proof corpus, five readiness-qualified interleaved runs measured in-memory cache build at 1.654 ms (1.559–2.309), process peak RSS at 4,052 KiB (3,844–4,200), and a checked bold Hack lookup at 0.093 ms (0.090–0.184). See [measurement method](docs/FONT-STACK.md#final-composed-root). The aarch64 `rust-fontconfig` and `ghostty-custom` packages build and pass their proofs in the aarch64 world build (m1-max, 2026-11-20). Open: the aarch64 guest runs and the macOS runs (owner-deferred).
- **Sequencing:** Owner-authorized campaign 3, before LAP-51. Prerequisite qualification remains open; this ticket records no adoption pass.

- **Progress:** The Graviola/rustcrypto musl package installs the daemon, ctl and exporter. Its wrapper drops to UID/GID 123 with only `CAP_SYS_TIME`; readiness means initialization, not synchronization. Real guest clocks converge from both positive and negative startup offsets. Forced restart, external-backstep restart/reselection and QMP pause/resume reselection pass. The loopback oracle pauses with the guest, and the external-backstep case does not prove convergence. An x86_64/KVM guest selected the authenticated external `time.cloudflare.com` NTS source before and after supervised restart; this does not independently measure clock accuracy. A controlled NTS guest verifies CA/name and `ntske/1`, records three authentication failures on tampered NTS replies before enabling valid replies, converges against the raw-clock oracle and restarts under supervision; its standalone runner passes end to end. Test-only chrony 4.9 confirms readiness while unsynchronized and startup stepping for both 20-second offset directions; its ahead runner also passes end to end. The package now persists steady frequency calibration without phase slew in a private UID/GID 123 directory. Twelve calibration tests pass on the host and in a root container. A controlled 100 ppm source proves learning and actual kernel frequency restoration after supervised restart and a fresh-kernel boot on the same state disk, before source selection and while unsynchronized. The exact final package also passes the NTS control with calibration enabled. The retained frequency shell runner also passes end to end on x86_64/KVM with the current ntpd-rs artifact closure, including both boots. This does not prove physical power-loss durability or hardware oscillator stability. Repository and trust-release v2 metadata now carry signed `issued-at`, and durable floors retain the greatest authenticated publication time rather than local wall observations. Legacy metadata/state require trusted reprovisioning that preserves generation floors. Existing installations must provision the reserved identity before enabling the service. On current master (2026-11-01) the behind, ahead, jump, pause, frequency, controlled NTS and external NTS (`time.cloudflare.com`) runners each pass on x86_64/KVM guests, and a new `slew` runner shows ntpd-rs correcting an 80 ms offset at about 0.5 ms per second without a step (converged in about four minutes) while chrony 4.9 also avoids a step but corrects about 32 ms in one sample, so the daemons agree on the no-step outcome and differ in slew rate. The `qemu-maintained` profile now runs ntpd-rs with an NTS-only configuration (`time.cloudflare.com`, `nts.netnod.se`, `nts.time.nl`; two must agree) and `tests/integration/maintained_ntp.py` qualifies it on the real network: readiness at stratum 16, synchronization to all three operators, supervised restart and reboot resynchronization, and a one-millisecond clock change over two minutes with NTS egress cut. PTB, the owner's third choice, completed NTS-KE but never answered NTS polls, so `nts.time.nl` replaced it. On 2026-11-11 `tests/integration/maintained_ntp_offline.py` booted the maintained image on a tap with no DHCP, route or resolver: ntpd-rs reached readiness at stratum 16 and kept the same process with no restarts for 120 s. A restart loop seen in the G2 drill came from that drill pre-creating `/var/lib/ntpd-rs` as root 0755, which the launcher refuses by design; the drill now leaves it to the launcher. aarch64 remains deferred. See [time discipline](docs/ROADMAP.md#time-discipline-and-bootstrap), [guest checks](docs/TESTING.md#run-the-disposable-ntp-guest), [snapshot policy](docs/PM.md) and [trust policy](docs/CERTIFICATE-TRUST.md).

### LAP-65 · P3 · Revendor gluon with its checked benchmark and capture its anchor

- **Area:** Performance
- **Where:** `gluon/` (vendored at `95bdcf5`), upstream `tests/benchmarks/libdrm.py`
- **Problem:** Upstream gluon `ba818ba` (laputa-systems/gluon#57) adds a real-project benchmark: libdrm 2.4.134, pinned by SHA-256, built by the pinned reference meson/ninja and by gluon with matching outputs and command counts, readiness-bracketed, with anchor verdicts. Its anchor is not captured (the host was busy on 2026-11-20), and Laputa still vendors `95bdcf5`, whose synthetic corpus tolerated failures.
- **Recommendation:** Revendor gluon at or after `ba818ba` with the usual package qualification, and capture the libdrm anchor on a quiet host as upstream `docs/benchmarks.md` describes. Acceptance: Laputa's vendored gluon includes the libdrm workload and upstream records an anchor that a run on a ready host reports within budget.
- **Fix with:** benchmark-checklist
- **Effort:** S
- **Progress:** Monotonic slew is done, consumer ntpd-rs. Kernel `434e2d626` derives CLOCK_MONOTONIC, CLOCK_MONOTONIC_COARSE and CLOCK_BOOTTIME from the raw clocksource slewed by the adjtimex frequency, keeps CLOCK_MONOTONIC_RAW unslewed, and publishes the slewed base to the vDSO. `run-ktest.sh kernel/core/comps/time` passes 12 of 12. The paired witness `clock_adjust` (`a_frequency_correction_slews_monotonic_and_boottime_but_not_raw`) passes in `qualify.sh clock-abi --backend both`: under +200 ppm for 2 s, MONOTONIC and BOOTTIME each run 200 to 700 µs ahead of MONOTONIC_RAW on Linux and Asterinas, bracketed by raw reads so a preempted read cannot fail it.
  Leap seconds are done, consumer ntpd-rs `leap_update`. Kernel `63abb4552` runs Linux's leap state machine on `STA_INS` and `STA_DEL` through `ADJ_STATUS`: the leap falls at the next UTC day boundary, CLOCK_REALTIME repeats or skips that second, the TAI offset moves with it, and clearing the bit cancels a pending leap. The paired witness `time/leap_status` passes in `qualify.sh clock-abi --backend both`; `qualify.sh all --backend both` passes and the A0 native accounting loses no pass (1326 passed, 0 new failures).
  Clock steps are done. Kernel `6ed63d5c2` (pin `d27b665aa`) adds `settimeofday` and `CLOCK_TAI`, and re-evaluates absolute realtime and TAI timers of `clock_nanosleep`, POSIX timers and timerfd after a step through `clock_settime`, `settimeofday` or `adjtimex` `ADJ_SETOFFSET`, cancelling timerfds armed with `TFD_TIMER_CANCEL_ON_SET`, as Linux `clock_was_set` does. The paired witnesses `time/settimeofday_step` and `time/realtime_step` run in `qualify.sh clock-abi`, which passes on both backends.

