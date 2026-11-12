# TODO

Prefix: LAP
Next: 57

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
- **Remaining:**
  - `c1b407a` starts the musl loader beneath the staging root with `FsRoot.command` (`execveat`). The loader still opens `makewhatis`, its libraries and the manpath by host path, so a swap of those paths between the rooted precondition checks and the loader's opens is not excluded.
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
- **Progress:** Typed IPv4 intent/ownership planning and bounded ordered replay pass nine native cases. A real read-only Docker veth capture reproduces the ownership conflict offline. Pure request encoding and strict read-only projection are tested. Independent review exposed a customized-route deletion hazard and an unobservable TOS selector. The unsafe live applier is withheld. The XSH side of the TOS gap is now closed in this checkout: `linux.network_dump` parses rtmsg byte 3 and exposes typed integer `tos` on route records, with decoder unit tests distinguishing TOS 0 from 8 and truncated headers still rejected. The Laputa side now consumes it: `network_project_dump` projects only ordinary TOS-0 main-table unicast defaults carrying the encoder's own attributes into `NetworkDefaultRoute`, refuses TOS-specific or customized selected defaults explicitly (even beside an ordinary default), ignores defaults on other links, and the capture driver rejects non-zero TOS. Thirteen kernel-projection cases pass. `network_project_stable_dumps` requires two identical consecutive complete dumps, and the capture driver's TOS rejection is tested offline through the pure `select_capture`. `linux.network_dump` already guarantees per-dump `NLMSG_DONE`, `NLM_F_DUMP_INTR` retry-then-issue and truncation issues; its four dumps carry no shared kernel generation. The IPv4 live applier is enabled: `network_reconcile` observes, plans purely, checks each step's precondition, applies through `net_state.apply` and re-observes over one `subscribe`/`drain` stream, returning `NetworkReconcile`. Both review hazards are closed by measurement. A zero-metric default is never created or removed, because on Linux 7.2.9 an explicit `RTA_PRIORITY` 0 still deletes a default of any metric. A selected default with unmodeled attributes is refused by projection and survives. In a disposable user+network namespace on a veth pair, the applier converges and preserves foreign and operator state. It plans nothing once settled, and it reports a conflict for an injected concurrent change and for a real ENOBUFS overrun. 36 native cases pass. Open: a KVM guest run of the applier, a second-process writer, IPv6, and a shared route-netlink generation across dumps.
- **Typed state:** `network_kernel.xsh` now plans over XSH's `lib.net_state` (XSH-38): `network_project_dump` delegates dump validation to `net_state.project`, `network_project_state` selects the managed link, IPv4 addresses and ordinary default routes from typed records (`other_attributes` replaces the attribute byte comparison), `network_project_stable_states` compares two `State`s, `network_change` maps a plan operation onto a `net_state.Change`, and `network_outcome`/`network_lost_events` map `apply` results and drained notices to replay events. Laputa's own raw-dump checks, attribute encoder and `NetworkKernelRequest` are deleted. Address request bytes are unchanged; route requests now carry `RTA_TABLE`, omit a zero priority, order gateway before interface, and removals send protocol 3 and type 1 instead of wildcards, which deletes exactly the boot-protocol unicast routes the controller adds. Fifteen kernel cases pass, and an unprivileged `unshare -Urn` run on a veth pair converged add, replace and removal of an owned address and default route through `net_state.apply` and re-observation. The disposable-guest driver (`network-policy-guest.xsh`) now uses `observe`, `apply`, `subscribe` and `drain`, but has not been re-run in a guest. `network-policy-capture.xsh` and the guest's fixture setup still read `linux.network_dump` directly. Route input-interface selectors are not modeled by `net_state.Route`, so the address-derived exemption no longer checks them.
- **XSH coordination:** `linux.netlink_route_request` now provides the bounded request/acknowledgement primitive with sequence/port validation, a deadline, and rejection of malformed or multipart replies. `network-policy-guest.xsh` consumes its errno record rather than treating a kernel refusal as a transport error; source checking and the eleven offline policy tests pass. A Linux x86_64/KVM guest built through the canonical seed path from clean XSH `8dfb48d07` confirms address ACK errno 0 and route refusal errno 101 as data, with partial and foreign address state retained. No real transport failure was induced; live-applier and convergence qualification remain open. Cross-dump atomicity would additionally need `linux.network_dump` to expose a single route-netlink generation, or to take all four dumps under one sequence-checked interruption flag. Not attempted here. See [network policy](packages/laputa-net/README.md).
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
- **Scope:** Retain `ffmpeg-build`, Mesa, musl, and Linux. FFmpeg/codec replacement, crabc evaluation or adoption, allocator work, and GPU-driver rewrites are explicitly excluded. Firewall and filesystem experiments are lower-confidence research; physical hardware stays deferred.
- **Acceptance:** Reproduce the census for the Tinyland/Ghostty profile and a separately identified Play build. Explain each native dependency and every unknown attribution. Establish differential correctness, failure, closure, and performance gates for each proposed replacement without changing production defaults.
- **Fix with:** architect, reference-parity, benchmark-checklist
- **Effort:** M (days)
- **Progress:** The census is a re-runnable check, `qualification/native-census/census.xsh`, and its findings and the replacement gates are in [Native census](docs/NATIVE-CENSUS.md). On the composed 11-root x86_64 profile it accounts for each graphical binary's `DT_NEEDED` providers and for the C and C++ linked statically into it:
  - **Ghostty:** twelve components plus Highway. Per-component symbol bytes come from a `-Dstrip=false` build of the pinned commit. Highway's 12 runtime symbols and 16 instantiated kernels total 6,716 bytes.
  - **Play v0.43.2:** libplacebo, shaderc, glslang, SPIRV-Tools, libstdc++ and libgcc. After the archive list was corrected to `libshaderc_combined.a`, 5,000,962 symbol bytes are attributed and 3,257 non-Rust bytes remain, all identified.
  - **Mesa:** lavapipe's static LLVM share is 22,663 symbols and 12,434,304 bytes.
  - **xsh:** mimalloc, zstd and liblzma (xz 5.8.4). GCC 9.4.0 is Rust's bundled musl sysroot.
  The census reports its open-attribution count and names each open entry, and its gates are proven live by negative runs: a removed provider, marker or `DT_NEEDED` entry each fails with exit 3. Every proposed replacement has differential correctness, failure, closure and performance gates defined; none has been run and no production default changed. The Mesa build now writes a libgallium link map: LLVM is 44,830,058 of 80,655,466 live input-section bytes, and llvm-toolchain's libc++/unwind is 416,944. The census reports 0 open attributions on the rebuilt root. Open: dropbear, the one cmake dependent not rebuilt after the cmake layout fix, because its SSH proof hung.
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
- **Problem:** The `network-state` cohort omits IPv6 state, address expiry, and route lookup without a dump. Local, broadcast, anycast and multicast routes through a device fail with `EOPNOTSUPP`. ICMP error delivery (roadmap Asterinas item 3) covers the unresolved-neighbor `EHOSTUNREACH` case; until then `ntpd-rs` does not leave an unreachable on-link source through its network-issue path.
- **Recommendation:** Add each operation with a paired Linux transcript in the existing cohorts. Sequence it after the ICMP slice, and leave IPv6 out until a consumer needs it.
- **Progress:** Slice 1, the IPv4 configuration ioctls `SIOCSIFADDR`, `SIOCSIFNETMASK`, `SIOCADDRT` and `SIOCDELRT`, landed in kernel `57aec8665` with the `ioctl-config` network-state case, which matches Linux's errno and resulting address and route state byte for byte. Their consumers are XSH's `ifconfig`, `linux.set_ipv4_address`, and `linux.add_default_ipv4_route`/`del_default_ipv4_route` (`ifup`, `ifdown`, the installer network boot, the trust and repo-snapshot guests). With XSH `d520fbcc5`, which removed the `dhcpc` status-3 traceback after the `carrier` case's SIGTERM, `qualify.sh all --backend both` passed every cohort and all ten recovery rounds; quiet-host A0 accounting kept all 1,281 original passes (1,326 passed, 25 failed, all in A0's failed set). Slice 2 (kernel `35db31eab`, `2fa8e057e`, `4f0f43390`) closes the DHCP cohort items. Links report `IFLA_CARRIER` from their state, the carrier change, up and down counts, `IFLA_STATS64` and `IFLA_STATS`; `carrier` compares them and `ifconfig eth0`'s `TX errors` line at every link step. Blackhole, unreachable, prohibit and throw routes install and refuse lookups with Linux's errno (`reject-routes`). A new `/dev/kmsg` serves the packaged `syslogd --kmsg` (`syslog`), whose socket side already matched Linux. On this pin `qualify.sh all --backend both` passed every cohort and all ten recovery rounds except one `syslog` ordering race in the case itself, which then passed three of three after the case waited for syslogd to log its socket records; quiet-host A0 accounting kept every original pass (1,326 passed, 25 failed, all in A0's failed set). The Linux reference now boots with `loglevel=3`, as the Firecracker guest does, so console printk cannot split a transcript line. Slice 3 (kernel `4479a5d1d`) answers `RTM_NEWLINK`, so XSH's `ip link set dev NAME up|down` works: the link is found by index or name, creation, exclusive creation and replacement fail with Linux's errnos, and the up flag changes through the `SIOCSIFFLAGS` path. The `link_state` witness pairs eight request shapes with Linux and the `netlink-link` case compares `ip link set` on `eth0` and `lo`. On this pin `qualify.sh all --backend both` passed every cohort and nine of ten recovery rounds; round 7 failed on the host before boot, when `prepare-xsh.sh`'s snapshot commit started git's detached auto-maintenance and it raced the stage's removal, which the build now prevents by committing with `gc.auto=0` and `maintenance.auto=false`. Quiet-host A0 accounting kept every original pass (1,326 passed, 25 failed, all in A0's failed set). Slice 4 (kernel `17a46dfe1`, `8eaec8a98`, `2ae01fac2`) puts the kernel's own log in `/dev/kmsg`, so `dmesg` and `syslogd --kmsg` see it: the ring holds records down to info level in static memory and `loglevel=` sets only the console level, as on Linux. Asterinas had logged every syscall entry and block request at info level, which flooded the ring, so those traces now log at debug level. The first full run then failed `syslog`: syslogd rate-limited 134 kernel records, each Asterinas's warning that `recvmsg` ignored `MSG_CMSG_CLOEXEC`. The flag now marks received `SCM_RIGHTS` descriptors close-on-exec, as Linux does, so they no longer leak across exec and the warning is gone; `unix_stream_err`'s `scm_rights_cmsg_cloexec` pairs it with Linux. The `device/kmsg` witness drains the boot log on both kernels and requires kernel-facility records in one gapless sequence with user writes. On this pin `qualify.sh all --backend both` passed every cohort and all ten recovery rounds; quiet-host A0 accounting kept every original pass (1,326 passed, 25 failed, all in A0's failed set). Slice 5 (kernel `e42a4911b`) accepts local, broadcast, anycast and multicast routes through a device with Linux 7.2.9's minimum scopes and errno order, and dumps their type, scope, protocol and table; the `network/route_types` witness pairs 180 assertions with Linux. On this pin `qualify.sh all --backend both` passed every cohort and three recovery rounds, and A0 accounting kept every original pass (1,326 passed, 25 failed, all in A0's failed set). Still open: route lookup without a dump, gateway variants of the device-bound route types, and address expiry, which nothing sets (`dhcpc` installs permanent addresses and the system report already reads Linux's forever lifetimes).
- **Fix with:** reference-parity
- **Effort:** L (weeks)

### LAP-56 · P2 · Wake xinit's scanner for a non-root control request

- **Area:** xinit supervision
- **Where:** `xinit/xinit.xsh` (`request_desired`, `wake_scanner`, `scan_units`), `xinit/docs/SUPERVISION.md`
- **Problem:** The scanner drains its control inbox only when it wakes, and when every unit is steady it sleeps for up to an hour. A queued request now wakes it with `SIGHUP`, sent only when the scanner marker's pid and start time match. An `xinit-admin` member cannot signal the root scanner, though, so its requests can wait until the scanner next wakes on its own.
- **Recommendation:** Give the scanner a wake channel the group can write to, such as a FIFO or socket in `/run/xinit` owned by `root:xinit-admin`, mode 0660. Include it in the scanner's wait, so a non-root request is applied within the same bound as a root one. Prove it with a guest case in which the operator restarts a steady service and observes the transition within a few seconds.
- **Fix with:** lifecycle-concurrency
- **Effort:** S
