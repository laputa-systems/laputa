# TODO

Prefix: LAP
Next: 59

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

### LAP-6 · P2 · Verify shared bootstrap changes on aarch64

- **Area:** Tests
- **Where:** `docs/TESTING.md:45`
- **Problem:** The completed x86_64 bootstrap changed shared PM, musl, headers, installer, and profile paths without a full aarch64 world rebuild or boot proof. aarch64 parity is unproven.
- **Recommendation:** Run the clean world build and both installer and profile proofs on a native aarch64 host. Fix failures before claiming parity.
- **Deferred:** aarch64 qualification is deferred pending a macOS aarch64 host via Docker; no Linux aarch64 hardware is available. Retain this finding, but exclude it from active backlog runs until the owner reopens it.
- **Blocked:** This campaign has an x86_64 host; the required native aarch64 build and guest proof remain unavailable. Unblock with a macOS aarch64 host via Docker.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-33 · P2 · Qualify one confined extraction and publication path

- **Area:** Privileged filesystem boundaries
- **Where:** `pm/root.xsh`, `pm/store.xsh`, `pm/generation.xsh`, `trust/release.xsh`, `tests/pm/`
- **Problem:** These paths already have staging and validation defenses; retaining an opened trusted root through every relevant mutation has not been qualified. Lexical relative-path validation is not sufficient evidence against concurrent filesystem replacement.
- **Recommendation:** Trace one artifact-to-generation path end to end, reuse XSH-37's existing Root-backed operations where appropriate, and eliminate repeated check-then-open decisions. Specify symlink/hard-link and special-file policy, no-replace publication, cleanup ownership and the fsync boundary. Repair only demonstrated gaps before widening the audit.
- **Acceptance:** Malicious archive entries, ancestor/symlink swaps, destination conflicts, interrupted cleanup and full disks cannot alter outside sentinels or remove the prior committed generation. Record atomic-visibility and durability evidence separately; process-kill tests alone do not satisfy power-loss claims.
- **Status:** Unblocked. Laputa has no XSH pin: ordinary targets build `XSH_ROOT`. XSH master `e10770744` provides `FsRoot.extract`, `rename`, `fsync` and `fs.root_install_file`; the frozen xinit snapshot `7261b0420` predates them, and so do host tools built before XSH `00e5f46a3`; rebuild those with `make host-xsh`. The traced path is `store.commit`, then `generation.compose`, `root.preflight`, `root_compose_into`, the overlay, the manual index and publication. It now runs beneath retained roots (`pm/confined.xsh`; [PM](docs/PM.md#filesystem-authority-limits)). `generation.compose_beneath` takes the publication root from the caller.
- **Evidence:** The Store hashes the payload once, during the copy (`fs.root_install_file_sha256`), and fails a commit whose copy differs from the staged digest (`test_store_rejects_a_payload_changed_after_it_was_hashed`); the manual-index preconditions refuse a tool swapped for a symlink out of the root (`test_manual_index_preconditions_do_not_follow_a_swapped_tool_out_of_the_root`); path-based `compose` opens its publication parent once before any other work, so the retained-root ancestor test covers it. `tests/pm/pm_confined_publication.xsh` covers ten hostile payload entry kinds, payload hard links, three destination conflicts, a climbing name, a publication ancestor replaced after open, staged-input symlinks, same-key staging reclamation, SIGKILL during staging and after publication, and ENOSPC on a 640 KiB tmpfs in an unprivileged user and mount namespace. None alters the outside sentinel or the prior generation.
  - Atomic visibility: kill tests observed both the staged and the published outcome, never a partial visible tree, and a retry succeeds.
  - Durability: `strace` shows every staged file and directory fsynced before the `RENAME_NOREPLACE` publish and the parent fsynced after it. Power loss is untested.
  - Against the pre-change code, the suite found no escape from hostile entries, conflicts, kills or full disks. It had no retained-root composition to test against ancestor replacement.
- **Manual indexing:** The existing `linux.run_confined` profile now accepts retained `FsRoot` authorities. The loader's child may open files beneath the selected root and write beneath its retained manual directory. Native and host boundary checks cover authority lifetime and ancestor replacement during policy setup. The real mandoc proof rejects program, library, manpath and ancestor swaps, preserves outside sentinels and refuses generation publication while retaining the prior generation. The preceding unconfined implementation executes the swapped outside program. Indexing requires Landlock ABI 6 and has no weaker fallback; the pinned Asterinas kernel lacks that capability, so a composition requesting an index fails closed there.
- **Remaining:**
  - One fsync per staged entry is unmeasured on large generations; owner timing gates are deferred (perf gate deferred: host busy).
- **Coordination:** Roadmap R4/R5; XSH-37 owns reusable host operations, not package policy.
- **Fix with:** isolate-effects
- **Effort:** M (days)

### LAP-16 · P3 · Exercise sound and wireless device support

- **Deferred:** Wireless and physical-device enablement are out of scope. Any separately selected virtio-audio proof must remain VM-only and must not enable physical drivers or firmware as a side effect. This item is not permission to widen hardware scope.
- **Area:** Tests
- **Where:** `system/qemu.xsh:1`, `packages/linux/files/config/aarch64/base-aarch64.fragment:1879`
- **Problem:** The graphical proof covers neither sound nor wireless devices. WLAN is disabled in the kernel fragments, and QEMU does not exercise the installed audio tools.
- **Recommendation:** Choose a supported device path, enable its kernel support, and verify the matching userspace against it.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-17 · P3 · Enable aarch64 perf events

- **Area:** Build
- **Where:** `packages/linux/files/config/aarch64/base-aarch64.fragment:233`
- **Problem:** The aarch64 kernel disables PERF_EVENTS while Laputa packages perf, leaving event recording unavailable.
- **Recommendation:** Enable perf events and check recording on a native aarch64 guest.
- **Deferred:** aarch64 qualification is deferred pending a macOS aarch64 host via Docker; no Linux aarch64 hardware is available. Retain this finding, but exclude it from active backlog runs until the owner reopens it.
- **Blocked:** Native aarch64 guest qualification is unavailable in this campaign; unblock with a macOS aarch64 host via Docker.
- **Fix with:** none
- **Effort:** S (hours)

### LAP-32 · P3 · Reconcile one managed virtual interface through a typed plan

- **Area:** Network policy
- **Where:** `packages/laputa-net/`, `profiles/`, `tests/system/`, `tests/integration/`
- **Problem:** One-shot interface setup does not provide an inspectable ownership-aware change plan or recovery from partial application. Replacing it with a larger opaque daemon would not exercise reusable XSH policy.
- **Recommendation:** Use XSH-38 for one virtual-Ethernet links/addresses/routes cohort. Write observation, pure planning and application/re-observation in XSH. Track owned resources separately from Tailscale/operator state; check stale preconditions and resynchronize after lost notifications. Coordinate resolver ownership and the maintained lease client under R2 rather than building a DHCP stack or universal provider framework.
- **Acceptance:** A no-change plan mutates nothing; reapplication converges; foreign addresses/routes survive; injected stale observations, failed operations and lost events lead to explicit conflict/re-observation, not fictitious rollback. The read-only plan is redacted and inspectable. Qualify IPv4/IPv6 separately on disposable VMs; physical networking stays excluded.
- **IPv4 qualification:** The controller uses XSH-38's `net_state.State` and `Change` records for observation, planning and mutation. The native network-policy suite passes 48 cases. `tests/system/network_policy_live_vm.sh` also passes the five-case live witness in an actual Linux 7.2.9 x86_64 KVM guest on canonical A with an explicit clean XSH `d7b4c9c85cbeefd20954156bd362805eabf4e35c` tool overlay (Laputa witness source `d3dddf0e3a80040ed577ae53118250e7faa78b0e`, retained evidence `.work/tmp/network-live.XXIbBAjD`). It converges and performs a no-op reapply, preserves foreign and peer addresses and operator/Tailscale-like routes, and refuses zero-metric or unmodeled-attribute changes before effects. A distinct child process changes the real kernel state between planning and applying. The controller rejects the stale plan with zero attempted changes, then converges from a fresh observation and again performs a no-op reapply. A real ENOBUFS overrun requires re-observation. All guest cases execute with no skips. The driver retains source/input hashes and checks the original root bundle remains unchanged. No production network changes were needed.
- **Remaining limits:** This proves ordered second-process concurrency at the plan/apply boundary, not atomicity between a per-operation check and its request or across separate kernel dumps. IPv6, Linux aarch64, Asterinas and physical networking remain outside this qualified cohort. Requalify changes that affect the executed network boundary. See [network qualification](packages/laputa-net/README.md#live-ipv4-guest-qualification).
- **Fix with:** single-source-of-truth
- **Effort:** L (weeks)

### LAP-20 · P3 · Fork the Rust toolchain build to retire gnu-stubs

- **Area:** Dependencies
- **Where:** `packages/gnu-stubs/PKGBUILD.xsh`, `packages/cargo/PKGBUILD.xsh`
- **Problem:** Laputa-built Rust packages no longer load libgcc_s.so.1: the cc wrapper links LLVM's static libunwind.a for `-static-libgcc`. Play 0.42.2 links its GCC runtime statically. One consumer still needs gnu-stubs at run time: the prebuilt upstream `cargo`, `rustc`, `rustdoc`, `rust-lld`, `rust-analyzer-proc-macro-srv` and `libstd-*.so` from static.rust-lang.org import `_Unwind_*` from libgcc_s.so.1, and Laputa cannot relink them. Builds also take gnu-stubs' empty crtbeginS.o and crtendS.o from cargo's closure.
- **Recommendation:** Fork the Rust toolchain build under laputa-systems and build cargo, rustc and the musl std from source against Laputa's musl with the `llvm-libunwind` std feature, so nothing imports libgcc_s. Retire libgcc_s.so.1 and the crt stubs once no recipe or prebuilt input needs them.
- **Acceptance:** No package's installed ELF files carry a libgcc_s NEEDED entry or a GCC runtime import, the PM ELF check reports no gnu-stubs provider, and Rust packages still build and pass their proofs with the source-built toolchain.
- **Parked:** The prebuilt `cargo`, `rustdoc`, `librustc_driver`, `libstd`, `rust-lld` and helper tools import libgcc_s; `rustc` does not. A source-built `cargo` needs an OpenSSL-compatible TLS library for curl, libgit2 and libssh2, and Laputa ships none: the routes are curl's rustls backend (needs `rustls-ffi`, which the rust source does not vendor, and drops ssh git), AWS-LC through `openssl-sys`, or a `cargo` without network TLS. Each adds work or a native dependency the owner does not want now, so gnu-stubs stays. The prebuilt 1.99.0 works as stage0 and Laputa's LLVM 23.1.5 as the external LLVM. The cargo proof skips its runtime check when `libgcc_s.so.1` is absent, so it must become a real run once gnu-stubs leaves its closure.
- **Fix with:** reference-parity, dead-code-archaeology
- **Effort:** L (weeks)

### LAP-40 · P4 · Pilot one trusted external CLI signature in Laputa recipes

- **Area:** Tooling
- **Where:** `packages/*/PKGBUILD.xsh`, `pm/`, `tests/pm/`, `docs/DEVELOPMENT.md`
- **Problem:** Native XSH APIs and typed recipe boundaries are checked, but flags of a pinned external executable can be mistyped without a diagnostic. An always-on command-signature registry would add drift and inappropriate implicit authority.
- **Recommendation:** Only after XSH-46 delivers its opt-in `xsht` checker, select one stable pinned executable invoked by a real recipe. Supply/reuse a reviewed complete flag signature and compare static diagnostics against the package's existing invocation tests. Keep dynamic targets and incomplete signatures conservative; the checker must not execute a tool to discover its options.
- **Acceptance:** A controlled misspelling is caught without launching any process; correct recipe invocations check and build unchanged. Version mismatches or unverified subcommands produce advisory diagnostics, never false hard errors. Report the actual maintenance/compile-time cost and drop the pilot if not worth it; CLI flags do not establish process effects.
- **Blocked:** The supplied fixed xsht has no opt-in external CLI signature checker; fixture research cannot establish the requested static diagnostic.
- **Coordination:** XSH-46 owns the optional tooling feature and signature trust policy.
- **Fix with:** reference-parity
- **Effort:** S (hours)

### LAP-51 · P3 · Establish the native-code census and replacement gates

- **Area:** Dependencies
- **Where:** `pm/elfdeps.xsh`, `docs/FONT-STACK.md`, `profiles/qemu-tinyland-ghostty.xsh`, `packages/wayland-libs-client/PKGBUILD.xsh`, `../play/scripts/audit-linux.sh`
- **Problem:** The ELF provider closure identifies libraries but does not account for statically incorporated C/C++ or establish that a Rust replacement preserves consumer contracts. The graphical profile and Play need a common, measured starting point before replacing libraries.
- **Recommendation:** After the active campaign, Play's SRT/Core Text migrations, and LAP-52, extend existing PM and application audits into a per-profile census. Count unique installed files, static native code, runtime-loaded providers, and build-only inputs separately. Prioritize the seatd client, remaining keyboard/Wayland consumers, distribution zlib, and later HarfRust/Swash qualification. XSH already uses Rust zlib and bzip2 backends. Preserve the shared font contract throughout.
- **Scope:** Retain `ffmpeg-build`, Mesa, musl, and Linux. FFmpeg/codec replacement, crabc evaluation or adoption, allocator work, and GPU-driver rewrites are explicitly excluded. The firewall is now `crabtables` (`nfcrt`); filesystem experiments are lower-confidence research; physical hardware stays deferred.
- **Acceptance:** Reproduce the census for the Tinyland/Ghostty profile and a separately identified Play build. Explain each native dependency and every unknown attribution. Establish differential correctness, failure, closure, and performance gates for each proposed replacement without changing production defaults.
- **Fix with:** architect, reference-parity, benchmark-checklist
- **Effort:** M (days)
- **Progress:** The census is a re-runnable check, `qualification/native-census/census.xsh`, and its findings and the replacement gates are in [Native census](docs/NATIVE-CENSUS.md). On the composed 11-root x86_64 profile it accounts for each graphical binary's `DT_NEEDED` providers and for the C and C++ linked statically into it:
  - **Ghostty:** twelve components plus Highway. Per-component symbol bytes come from a `-Dstrip=false` build of the pinned commit. Highway's 12 runtime symbols and 16 instantiated kernels total 6,716 bytes.
  - **Play v0.43.2:** libplacebo, shaderc, glslang, SPIRV-Tools, libstdc++ and libgcc. After the archive list was corrected to `libshaderc_combined.a`, 5,000,962 symbol bytes are attributed and 3,257 non-Rust bytes remain, all identified.
  - **Mesa:** lavapipe's static LLVM share is 22,663 symbols and 12,434,304 bytes.
  - **xsh:** mimalloc, zstd and liblzma (xz 5.8.4). GCC 9.4.0 is Rust's bundled musl sysroot.
  The census reports its open-attribution count and names each open entry, and its gates are proven live by negative runs: a removed provider, marker or `DT_NEEDED` entry each fails with exit 3. Every proposed replacement has differential correctness, failure, closure and performance gates defined; none has been run and no production default changed. The Mesa build now writes a libgallium link map: LLVM is 44,830,058 of 80,655,466 live input-section bytes, and llvm-toolchain's libc++/unwind is 416,944. The census reports 0 open attributions on the rebuilt root. No cmake dependent is left unrebuilt: dropbear, the last, was removed when OxiSH replaced it (LAP-57).
- **Design:** [C-free userspace direction](docs/rfc/LAP-51-c-free-userspace.md)

### LAP-52 · P3 · Share rust-fontconfig across Ghostty and Play

- **Area:** Dependencies
- **Where:** `packages/`, `docs/FONT-STACK.md`, `../ghostty/src/font/`, `../play/rust/player-overlay/src/text/linux.rs`
- **Problem:** The canonical graphical stack still relies on C Fontconfig and Expat. Upstream rust-fontconfig has not been qualified as a shared discovery provider for both consumers.
- **Recommendation:** After the shared native font stack and Play SRT/Core Text migrations pass, package pinned upstream rust-fontconfig as one versioned musl shared library. Adapt both consumers to its C API, retain shared FreeType and HarfBuzz, and qualify configuration, caching, fallback, rendered output, ABI, closure, and measured costs before removing the native provider.
- **Acceptance:** Both applications dynamically resolve the same Laputa library. International discovery and cluster-safe fallback pass real rendering and guest proofs. Native Fontconfig and unused Expat leave the canonical graphical closure. Preserve macOS and existing security gates. Report exact upstream and repository revisions, SONAME, features, results, and installed footprint.
- **Progress:** The package builds the laputa-systems fork tag `v5.0.2-laputa.2`, which adds `fc_chain_candidates_for_text`: fonts covering a whole cluster, ranked by declared OpenType script, with a color flag. Ghostty `c4f036c72` (`-Dfont-backend=rust_fontconfig_freetype`) and Play 0.43.2 both need `librust_fontconfig.so.5.0.2` and not `libfontconfig.so.1`; their package proofs assert it. `rust-fontconfig` owns `/etc/fonts/fonts.conf`, and the `fontconfig` package and Expat no longer belong to the canonical closure. The x86_64/KVM guest proof (`make profile-test`, 2026-11-09) passes keyboard input, presentation, the crash, broker-loss and scanner recoveries, the security gates, and named screenshots of Ghostty and Play whose Arabic, Devanagari, CJK and ZWJ emoji lines are checked for tofu by `system/text_pixels.xsh`; the profile forbids `fontconfig` and `expat`. The aarch64 Ghostty and Play runs are deferred with the rest of the campaign. The stale `qualification/ghostty-shared` candidate recipe is removed; nothing consumed it. The final canonical 11-root x86_64 generation, composed after rebuilding 35 plan nodes that the gluon migration and the LLVM seed move had invalidated, has 31 packages, 1,630 unique regular files, 335,939,380 bytes and 48 ELF files, against 32, 1,548, 336,210,344 and 49 at the `fe1912a` baseline ([Shared font stack](docs/FONT-STACK.md#final-composed-root)). It has no `fontconfig` or `expat` package and no ELF needs `libfontconfig.so.1` or `libexpat.so.1`; the `rust-fontconfig`, `ghostty-custom` and `play` proofs pass. Open: the aarch64 and macOS runs (owner-deferred); timing and cache-build peak RSS are unmeasured.
- **Sequencing:** Owner-authorized campaign 3, before LAP-51. Prerequisite qualification remains open; this ticket records no adoption pass.
- **Fix with:** architect, reference-parity, benchmark-checklist
- **Effort:** L (weeks)
- **Design:** [Shared upstream rust-fontconfig](docs/rfc/LAP-52-rust-fontconfig.md)

### LAP-47 · P2 · Complete ntpd-rs qualification and clock bootstrap policy

- **Area:** Time discipline
- **Where:** `ntpd-rs/`, imported from the `laputa-systems/ntpd-rs` fork at `910ecd0`, `2.0.0-alpha.20260715`
- **Problem:** aarch64 runtime qualification of the maintained NTS clock remains unproven; the x86_64 profile is qualified (see Progress).
- **Recommendation:** Qualify the remaining cases in disposable guests before enabling an authenticated production configuration. Never alter the host clock. Cold boot requires trustworthy RTC or operator-set time; preserve TLS and snapshot expiry verification.
- **Progress:** The Graviola/rustcrypto musl package installs the daemon, ctl and exporter. Its wrapper drops to UID/GID 123 with only `CAP_SYS_TIME`; readiness means initialization, not synchronization. Real guest clocks converge from both positive and negative startup offsets. Forced restart, external-backstep restart/reselection and QMP pause/resume reselection pass. The loopback oracle pauses with the guest, and the external-backstep case does not prove convergence. An x86_64/KVM guest selected the authenticated external `time.cloudflare.com` NTS source before and after supervised restart; this does not independently measure clock accuracy. A controlled NTS guest verifies CA/name and `ntske/1`, records three authentication failures on tampered NTS replies before enabling valid replies, converges against the raw-clock oracle and restarts under supervision; its standalone runner passes end to end. Test-only chrony 4.9 confirms readiness while unsynchronized and startup stepping for both 20-second offset directions; its ahead runner also passes end to end. The package now persists steady frequency calibration without phase slew in a private UID/GID 123 directory. Twelve calibration tests pass on the host and in a root container. A controlled 100 ppm source proves learning and actual kernel frequency restoration after supervised restart and a fresh-kernel boot on the same state disk, before source selection and while unsynchronized. The exact final package also passes the NTS control with calibration enabled. The retained frequency shell runner also passes end to end on x86_64/KVM with the current ntpd-rs artifact closure, including both boots. This does not prove physical power-loss durability or hardware oscillator stability. Repository and trust-release v2 metadata now carry signed `issued-at`, and durable floors retain the greatest authenticated publication time rather than local wall observations. Legacy metadata/state require trusted reprovisioning that preserves generation floors. Existing installations must provision the reserved identity before enabling the service. On current master (2026-11-01) the behind, ahead, jump, pause, frequency, controlled NTS and external NTS (`time.cloudflare.com`) runners each pass on x86_64/KVM guests, and a new `slew` runner shows ntpd-rs correcting an 80 ms offset at about 0.5 ms per second without a step (converged in about four minutes) while chrony 4.9 also avoids a step but corrects about 32 ms in one sample, so the daemons agree on the no-step outcome and differ in slew rate. The `qemu-maintained` profile now runs ntpd-rs with an NTS-only configuration (`time.cloudflare.com`, `nts.netnod.se`, `nts.time.nl`; two must agree) and `tests/integration/maintained_ntp.py` qualifies it on the real network: readiness at stratum 16, synchronization to all three operators, supervised restart and reboot resynchronization, and a one-millisecond clock change over two minutes with NTS egress cut. PTB, the owner's third choice, completed NTS-KE but never answered NTS polls, so `nts.time.nl` replaced it. On 2026-11-11 `tests/integration/maintained_ntp_offline.py` booted the maintained image on a tap with no DHCP, route or resolver: ntpd-rs reached readiness at stratum 16 and kept the same process with no restarts for 120 s. A restart loop seen in the G2 drill came from that drill pre-creating `/var/lib/ntpd-rs` as root 0755, which the launcher refuses by design; the drill now leaves it to the launcher. aarch64 remains deferred. See [time discipline](docs/ROADMAP.md#time-discipline-and-bootstrap), [guest checks](docs/TESTING.md#run-the-disposable-ntp-guest), [snapshot policy](docs/PM.md) and [trust policy](docs/CERTIFICATE-TRUST.md).
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-57 · P2 · Qualify the ssh-build `oxish` release in the guest

- **Area:** Remote administration
- **Where:** `packages/oxish/PKGBUILD.xsh`, `docs/REMOTE-ADMIN.md`, `docs/QEMU.md`
- **Problem:** Laputa has no Dropbear; the maintained profile's SSH server is `oxish-server --mode login` from the `oxish` package. The recipe pins ssh-build `release-ba4e5e269b1737b32cf7cdaa08e739ec06712cf5` (all six executables, SHA-256 per architecture from its `SHA256SUMS`). The VM drills that boot the guest (`remote_admin.py`, `ssh_network_recovery.py`, `g2_lifecycle.py`, `maintained_guest.py`, `backup_schedule.py`, `diagnostics_reboot.py`, `dhcp_lifecycle.py`, `installer-qemu-test.xsh`) are migrated but have not run against the real archive. No Asterinas run exists for the login server.
- **Recommendation:** Run `make fetch`, `make build PKGS=oxish`, the package proof, then each drill above, and record the outcomes in [Remote administration](docs/REMOTE-ADMIN.md) and [QEMU](docs/QEMU.md). Confirm that `xsh-login` sessions, the 96 MiB staging transfer and the pinned-fingerprint client behave against `oxish-server` as they did against Dropbear.
- **Fix with:** reference-parity
- **Effort:** S (hours)

### LAP-58 · P2 · Qualify the crabtables firewall in the guest

- **Area:** Networking
- **Where:** `packages/crabtables/PKGBUILD.xsh`, `packages/crabtables/service.xsh`, `docs/QEMU.md`, `docs/TESTING.md`
- **Problem:** The `crabtables` package (`nfcrt`, pinned laputa-systems/crabtables `cb27bf901af60cd6026c4b34795a80ba0f6b3225`) replaced the C nftables, libnftnl and libmnl packages. `make build PKGS=crabtables` builds it against the Laputa musl/Rust toolchain and its proof compiles the shipped ruleset without `CAP_NET_ADMIN`; container evidence shows that ruleset loads to the same kernel ruleset as `nft` 1.1.6. The guest drills (`maintained_guest.py --firewall`, `maintained_ntp_offline.py`, and the other drills that stage `/etc/nftables.conf`) have not run. The Asterinas guest has no `NETLINK_NETFILTER` socket, so the firewall service cannot run there.
- **Recommendation:** Run each drill above and record the outcomes in [QEMU](docs/QEMU.md); fix defects they find upstream in crabtables and move the recipe pin and Cargo.lock checksum together. Keep Asterinas out of the firewall profile until its kernel implements `NETLINK_NETFILTER` and nf_tables, fixed in the pinned fork.
- **Fix with:** reference-parity
- **Effort:** S (hours)

### LAP-54 · P3 · Close the Asterinas clock ABI and timestamp obligations

- **Area:** Asterinas clock
- **Where:** `asterinas/` (kernel `time` and `net` code), `infra/asterinas/`
- **Problem:** `ADJ_OFFSET`, `ADJ_TICK`, the adjtime modes, `STA_PLL`, `STA_FLL`, and `STA_FREQHOLD` fail with `EINVAL` where Linux accepts them. Absolute realtime timers are not re-armed by a step, `settimeofday` is missing, and the vDSO reads through the system call while a correction is active. Transmit timestamps without `OPT_TSONLY` and hardware timestamps are missing, Firecracker has no RTC, and the 1000 s jump rejection is unexplored.
- **Recommendation:** Take each obligation as a kernel change with a witness paired against Linux in `infra/asterinas/qualify.sh clock-abi` or `clock`, driven by a consumer that needs it. Do not claim an obligation without its paired witness.
- **Progress:** Monotonic slew is done, consumer ntpd-rs. Kernel `434e2d626` derives CLOCK_MONOTONIC, CLOCK_MONOTONIC_COARSE and CLOCK_BOOTTIME from the raw clocksource slewed by the adjtimex frequency, keeps CLOCK_MONOTONIC_RAW unslewed, and publishes the slewed base to the vDSO. `run-ktest.sh kernel/core/comps/time` passes 12 of 12. The paired witness `clock_adjust` (`a_frequency_correction_slews_monotonic_and_boottime_but_not_raw`) passes in `qualify.sh clock-abi --backend both`: under +200 ppm for 2 s, MONOTONIC and BOOTTIME each run 200 to 700 µs ahead of MONOTONIC_RAW on Linux and Asterinas, bracketed by raw reads so a preempted read cannot fail it.
  Leap seconds are done, consumer ntpd-rs `leap_update`. Kernel `63abb4552` runs Linux's leap state machine on `STA_INS` and `STA_DEL` through `ADJ_STATUS`: the leap falls at the next UTC day boundary, CLOCK_REALTIME repeats or skips that second, the TAI offset moves with it, and clearing the bit cancels a pending leap. The paired witness `time/leap_status` passes in `qualify.sh clock-abi --backend both`; `qualify.sh all --backend both` passes and the A0 native accounting loses no pass (1326 passed, 0 new failures).
- **Fix with:** reference-parity
- **Effort:** L (weeks)

### LAP-55 · P3 · Close the Asterinas IPv4 state and DHCP obligations

- **Area:** Asterinas networking
- **Where:** `asterinas/` (kernel `net` code), `infra/asterinas/`
- **Qualified IPv4 scope:** Published kernel `d59567c40` with XSH `d7b4c9c85` supports the configuration ioctls, link/carrier state and counters, address/route notifications, DHCP acquire/renewal/reconfiguration/NAK/restart/carrier recovery, and logging exercised by the paired cohorts. Device-bound local, broadcast, anycast and multicast routes include Linux-compatible gateway scope/error rules. Non-dump output route lookup covers source, output interface, mark, uid and `RTM_F_FIB_MATCH`. Finite preferred/valid lifetimes deprecate and expire addresses, remove derived routes, cancel removed-address timers and retain deadlines across netmask changes. The expiry, gateway and lookup transcripts match Linux exactly.
- **Final qualification:** On 2026-11-12, clean Laputa `33bffe43d` passed fresh `published-inputs` and `LAPUTA_RECOVERY_REPEATS=10 bash infra/asterinas/qualify.sh all --backend both`: every primary cohort and all ten paired boot/restart/carrier rounds passed, exit 0. Final-bundle discovery used its actual bundled `xsht` and found 15,649 IDs. The bounded A0 selection passed both exact-ID preservation checks: all original 1,281 and later 1,326 passes remain passing. Accounting is 1,330 passed, 29 failed, 49 skipped, 14,241 unexecuted, zero unknown and no interrupted batches. All failures are in the original failed set; the four additional failures relative to the later 25-failure receipt are wget fixture cases that were then unexecuted and require absent Perl. Four new DHCP client/machine cases pass. This does not claim a full native-suite pass.
- **Receipts:** `.work/wt/final-asterinas/.work/tmp/final-all-both-10.log`, its exit and hash receipts, `a0-final/final-preservation.json`, both accounting logs and `a0-final/results/accounting.json` (SHA-256 `e4ba100c6af14eb224972fbf70662a37a6f441ec8af98dbaf4eb96cf118b79dc`). [Asterinas](docs/ASTERINAS.md) records both immutable bundle IDs and the kernel ELF identity; `final-ipv4-evidence/` retains the paired transcripts and raw logs.
- **Remaining limits:** IPv6 stays deferred until a consumer needs it. Nonzero `RTA_IIF` input-route queries remain unsupported.
- **Fix with:** reference-parity
- **Effort:** L (weeks)
