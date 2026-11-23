Prefix: LAP
Next: 92

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

### LAP-91 · P2 · musl regcomp overflows the C stack on long literal patterns

- **Area:** Security
- **Where:** `packages/musl/PKGBUILD.xsh` (musl 1.2.6 `src/regex/regcomp.c`, TRE's recursive parse and position passes)
- **Problem:** `regcomp()` on a pattern of 200,000 literal `a` characters (`REG_EXTENDED|REG_NOSUB`) segfaults under an 8 MiB stack with unpatched musl 1.2.6; 100,000 and 150,000 compile, and 300,000 returns `REG_ESPACE`. Upstream commit 7813e911 (the LAP-87 regcomp overflow fix) raises the stack limit, so with it 300,000 also segfaults. A program that compiles an untrusted regex can be crashed rather than handed an error. Reproduced on 2026-11-23 with static test programs linked against both builds; the recursing function was not identified, and both cases compile under `ulimit -s unlimited`.
- **Recommendation:** Find the recursing pass, bound its depth so oversized patterns fail with `REG_ESPACE`, and carry it as a checksum-bound patch in a `laputa-systems` musl fork with an upstream draft. Keep a child-process regression for each length above.
- **Fix with:** security, os-boundaries
- **Effort:** M

### LAP-87 · P2 · The musl regcomp and GB18030 backports are unproven on aarch64

- **Area:** Security
- **Where:** `packages/musl/PKGBUILD.xsh` (patches `musl-regcomp-int-overflow.patch` from musl 7813e911 and `musl-gb18030-iconv-decoder.patch` from 67219f01, `rel = "17"`); `packages/musl/proof.xsh`
- **Problem:** Both CVE backports (CVE-2026-107891, CVE-2026-6042) are applied for every architecture and proven on x86_64: the GB18030 regression programs fail on unpatched 1.2.6 and pass patched, and the regcomp family passes patched. The regcomp overflow itself was not triggered, since it needs about 2^31 positions. The aarch64 musl build and the cross-compile of the proof programs have not run, because the x86_64 host has no aarch64 seed.
- **Recommendation:** On the aarch64 host, run `make seed` and `make build PKGS=musl` and record the proof result here before closing.
- **Effort:** S

### LAP-88 · P1 · C zlib is 1.3.2, without the memory-safety fixes released in 1.4

- **Area:** Security
- **Where:** `packages/zlib/PKGBUILD.xsh:12,87` (`ver = "1.3.2"`, `libz.so.1.3.2`); `docs/NATIVE-CENSUS.md` (zlib gate evidence, whose differential oracle is this library)
- **Problem:** Per the 2026-11-23 tech scout, zlib 1.4 (2026-11-04) fixes CVE-2026-85091 in nonblocking `gzwrite()`, `inflateGetDictionary()` buffer handling, and other specialized operations. Laputa builds 1.3.2. The fixes matter only where a consumer reaches the affected API, which linkage alone does not show. LAP-51 Track C's zlib-rs differential uses this 1.3.2 build as its oracle, so it cannot establish compatibility with 1.4's corrected failure behavior. unproven: the release details come from the scout and were not re-checked here.
- **Recommendation:** Upgrade the C reference to 1.4, qualify its changed failure-path behavior against the installed consumers (FreeType, libpng, Play), then move the zlib-rs differential's oracle to 1.4 and add 1.4's security-relevant inputs, separating intended behavior changes from regressions.
- **Fix with:** security
- **Effort:** M

### LAP-79 · P2 · Installer marks interpreted su and passwd setuid

- **Area:** Security
- **Where:** `installer/setup-laputa.xsh:127-135`, `packages/xsh/PKGBUILD.xsh:102,125,199-204`, XSH `core/su.xsh:61`, XSH `core/lib/auth.xsh:120-205`
- **Problem:** The installer runs `chmod 0o4755` on `/usr/bin/su` and `/usr/bin/passwd`. Both are symlinks to interpreted XSH applets under `/usr/lib/xsh/core/`, so the chmod sets setuid on the script files. Linux ignores setuid on interpreted scripts, so a non-root user's `su` and `passwd` cannot gain the privilege they need; the feature is silently broken. The bits are also a latent escalation: the applets read account files chosen by `XSH_PASSWD_FILE` and `XSH_SHADOW_FILE` (XSH-145), so any kernel or wrapper that honors the bit lets a caller authenticate against a file they wrote. unproven: whether the pinned Asterinas kernel honors setuid on interpreted files was not checked.
- **Recommendation:** Stop setting setuid on interpreted applets. Provide privileged password change and user switching through `doas` (already setuid and audited) or a small compiled helper, and add a profile check that no setuid file in the root starts with `#!`.
- **Fix with:** security, os-boundaries
- **Effort:** M
- **Deferred:** Wireless and physical-device enablement are out of scope. Any separately selected virtio-audio proof must remain VM-only and must not enable physical drivers or firmware as a side effect. This item is not permission to widen hardware scope.

### LAP-89 · P2 · A readiness timeout satisfies a required dependency

- **Area:** Supervision
- **Where:** `xinit/xinit.xsh:1834-1847` (`gate_satisfied`), `xinit/docs/INIT.md:245-252`, `xinit/docs/SUPERVISION.md:56`
- **Problem:** When a unit's `ready()` hook or notify byte does not arrive within `ready_timeout_ms`, the unit becomes `running` with `ready` false. `gate_satisfied` checks only `state == "running"` for `dependencies.need`, so a service that never became ready releases its dependents, which then start against a service that has said it cannot serve. The docs describe the promotion but not that it satisfies `need`. unproven: whether `need` is meant to require readiness is an owner decision.
- **Recommendation:** Decide the contract. Either make `need` wait for `ready` and report a timed-out dependency as blocking, or state in INIT.md that `need` gates only on the process running and add a separate readiness-gated dependency kind. Add a lifecycle test where a needed service times out unready.
- **Fix with:** lifecycle-concurrency, error-model
- **Effort:** S

### LAP-80 · P2 · xinit's non-PID1 test opt-in changes control-plane authorization

- **Area:** Init
- **Where:** `xinit/xinit.xsh:137-139` (`test_mode`), `:252-269` (`control_group_gid`, `control_owner_uid`, `control_sender_permitted`), `:2385` (`scan_units` calls `unix.pid1_setup(..., allow_non_pid1: true)` ungated), `xinit/docs/INIT.md:115-135`
- **Problem:** AGENTS.md requires that xinit test-only switches not change production behavior, and INIT.md says `XINIT_TEST_ALLOW_NON_PID1` enables test controls only. In code it also replaces the control-plane authorization: with the opt-in set and pid not 1, the control group is the run directory's gid instead of `xinit-admin`, the owner uid is the euid instead of 0, and any sender with the same euid is permitted. The gate is `pid != 1`, which holds for the scanner and every `xinit VERB` client, not only for fixtures. `scan_units` passes `allow_non_pid1: true` with no gate at all. The scanner inherits PID 1's environment, so no exploit was shown, but the invariant the guide states is not the one the code keeps.
- **Recommendation:** Make the authorization functions independent of test mode and give fixtures a real `xinit-admin` group (or an injected owner and group in the fixture harness). Gate `scan_units`' `allow_non_pid1` on test mode, and add a test that a non-PID1 production scanner rejects a sender outside `xinit-admin` with the opt-in set.
- **Fix with:** security, isolate-effects
- **Effort:** M
- **Acceptance:** No package's installed ELF files carry a libgcc_s NEEDED entry or a GCC runtime import, the PM ELF check reports no gnu-stubs provider, and Rust packages still build and pass their proofs with the source-built toolchain.
- **Parked:** The prebuilt `cargo`, `rustdoc`, `librustc_driver`, `libstd`, `rust-lld` and helper tools import libgcc_s; `rustc` does not. A source-built `cargo` needs an OpenSSL-compatible TLS library for curl, libgit2 and libssh2, and Laputa ships none: the routes are curl's rustls backend (needs `rustls-ffi`, which the rust source does not vendor, and drops ssh git), AWS-LC through `openssl-sys`, or a `cargo` without network TLS. Each adds work or a native dependency the owner does not want now, so gnu-stubs stays. The prebuilt 1.99.0 works as stage0 and Laputa's LLVM 23.1.5 as the external LLVM. The cargo proof skips its runtime check when `libgcc_s.so.1` is absent, so it must become a real run once gnu-stubs leaves its closure.

### LAP-86 · P3 · Asterinas rejects malformed trailing netlink attributes that Linux ignores

- **Area:** Asterinas fork · netlink
- **Where:** `asterinas/kernel/core/src/net/socket/netlink/message/attr/mod.rs` (`AttrValidation::LegacyChange`), `asterinas/test/initramfs/src/regression/network/rtnl_ack.c:114`
- **Problem:** A legacy (non-strict) `RTM_NEWADDR` whose last attribute overruns the message gets `EINVAL` on Asterinas. Linux parses these requests with `NL_VALIDATE_LIBERAL`, warns about the leftover bytes and applies the attributes before them. The fork chose the stricter answer in `12249b0fe` and marked the `rtnl_ack` case Asterinas-only. Upstream's 2026 netlink framework had moved Asterinas to the Linux behavior; the 2026-11-21 rebase restored the fork's divergence with `LegacyChange` so the witness keeps passing.
- **Recommendation:** Once the Linux backend can run again, record Linux's reply for the three malformed-attribute requests in `rtnl_ack` on both backends. If Linux acknowledges them, drop `LegacyChange`, change the case to expect the Linux reply (deleting the address it creates), and run it on both backends.
- **Fix with:** reference-parity
- **Effort:** S
- **Acceptance:** `qualify.sh all --backend both` passes `network/rtnl_ack` with the malformed-attribute case run on both backends and the same result on each.

### LAP-16 · P3 · Exercise sound and wireless device support

- **Area:** Tests
- **Where:** `system/qemu.xsh:1`, `packages/linux/files/config/aarch64/base-aarch64.fragment:1879`
- **Problem:** The graphical proof covers neither sound nor wireless devices. WLAN is disabled in the kernel fragments, and QEMU does not exercise the installed audio tools.
- **Recommendation:** Choose a supported device path, enable its kernel support, and verify the matching userspace against it.
- **Fix with:** reference-parity
- **Effort:** M
- **Acceptance:** Both applications dynamically resolve the same Laputa library. International discovery and cluster-safe fallback pass real rendering and guest proofs. Native Fontconfig and unused Expat leave the canonical graphical closure. Preserve macOS and existing security gates. Report exact upstream and repository revisions, SONAME, features, results, and installed footprint.
- **Progress:** The package builds the laputa-systems fork tag `v5.0.2-laputa.2`, which adds `fc_chain_candidates_for_text`: fonts covering a whole cluster, ranked by declared OpenType script, with a color flag. Ghostty `c4f036c72` (`-Dfont-backend=rust_fontconfig_freetype`) and Play 0.43.2 both need `librust_fontconfig.so.5.0.2` and not `libfontconfig.so.1`; their package proofs assert it. `rust-fontconfig` owns `/etc/fonts/fonts.conf`, and the `fontconfig` package and Expat no longer belong to the canonical closure. The x86_64/KVM guest proof (`make profile-test`, 2026-11-09) passes keyboard input, presentation, the crash, broker-loss and scanner recoveries, the security gates, and named screenshots of Ghostty and Play whose Arabic, Devanagari, CJK and ZWJ emoji lines are checked for tofu by `system/text_pixels.xsh`; the profile forbids `fontconfig` and `expat`. The aarch64 Ghostty and Play runs are deferred with the rest of the campaign. The stale `qualification/ghostty-shared` candidate recipe is removed; nothing consumed it. The final canonical 11-root x86_64 generation, composed after rebuilding 35 plan nodes that the gluon migration and the LLVM seed move had invalidated, has 31 packages, 1,630 unique regular files, 335,939,380 bytes and 48 ELF files, against 32, 1,548, 336,210,344 and 49 at the `fe1912a` baseline ([Shared font stack](docs/FONT-STACK.md#final-composed-root)). It has no `fontconfig` or `expat` package and no ELF needs `libfontconfig.so.1` or `libexpat.so.1`; the `rust-fontconfig`, `ghostty-custom` and `play` proofs pass. On the six-font package-proof corpus, five readiness-qualified interleaved runs measured in-memory cache build at 1.654 ms (1.559–2.309), process peak RSS at 4,052 KiB (3,844–4,200), and a checked bold Hack lookup at 0.093 ms (0.090–0.184). See [measurement method](docs/FONT-STACK.md#final-composed-root). The aarch64 `rust-fontconfig` and `ghostty-custom` packages build and pass their proofs in the aarch64 world build (m1-max, 2026-11-20). Open: the aarch64 guest runs and the macOS runs (owner-deferred).
- **Sequencing:** Owner-authorized campaign 3, before LAP-51.

### LAP-20 · P3 · Fork the Rust toolchain build to retire gnu-stubs

- **Area:** Dependencies
- **Where:** `packages/gnu-stubs/PKGBUILD.xsh`, `packages/cargo/PKGBUILD.xsh`
- **Problem:** Laputa-built Rust packages no longer load libgcc_s.so.1: the cc wrapper links LLVM's static libunwind.a for `-static-libgcc`. Play 0.42.2 links its GCC runtime statically. One consumer still needs gnu-stubs at run time: the prebuilt upstream `cargo`, `rustc`, `rustdoc`, `rust-lld`, `rust-analyzer-proc-macro-srv` and `libstd-*.so` from static.rust-lang.org import `_Unwind_*` from libgcc_s.so.1, and Laputa cannot relink them. Builds also take gnu-stubs' empty crtbeginS.o and crtendS.o from cargo's closure.
- **Recommendation:** Fork the Rust toolchain build under laputa-systems and build cargo, rustc and the musl std from source against Laputa's musl with the `llvm-libunwind` std feature, so nothing imports libgcc_s. Retire libgcc_s.so.1 and the crt stubs once no recipe or prebuilt input needs them.
- **Fix with:** reference-parity, dead-code-archaeology
- **Effort:** L

### LAP-52 · P3 · Share rust-fontconfig across Ghostty and Play

- **Area:** Dependencies
- **Where:** `packages/`, `docs/FONT-STACK.md`, `../ghostty/src/font/`, `../play/rust/player-overlay/src/text/linux.rs`
- **Problem:** The canonical graphical stack still relies on C Fontconfig and Expat. Upstream rust-fontconfig has not been qualified as a shared discovery provider for both consumers.
- **Recommendation:** After the shared native font stack and Play SRT/Core Text migrations pass, package pinned upstream rust-fontconfig as one versioned musl shared library. Adapt both consumers to its C API, retain shared FreeType and HarfBuzz, and qualify configuration, caching, fallback, rendered output, ABI, closure, and measured costs before removing the native provider.
- **Fix with:** architect, reference-parity, benchmark-checklist
- **Effort:** L
- **Design:** [Shared upstream rust-fontconfig](docs/rfc/LAP-52-rust-fontconfig.md)

### LAP-90 · P3 · laputa-net always depends on wpa_supplicant

- **Area:** Closure
- **Where:** `packages/laputa-net/PKGBUILD.xsh:24-25` (`runtime_only_deps = ["wpa_supplicant", "xinit", "xsh"]`)
- **Problem:** Every root that installs laputa-net also installs wpa_supplicant, including `qemu-maintained`, whose virtio networking never associates with Wi-Fi. Wireless is outside the maintained VM scope (LAP-16), so the dependency adds closure, attack surface and build cost with no consumer in those profiles.
- **Recommendation:** Make wpa_supplicant a profile-selected dependency of the wireless path only, and check that the maintained QEMU roots no longer contain it while a wireless-enabled profile still does.
- **Fix with:** api-surface-and-module-boundaries
- **Effort:** S

### LAP-81 · P3 · The rescue decision module has no production caller

- **Area:** System
- **Where:** `system/rescue.xsh:21,27,48` (`rescue_repair_argv`, `rescue_classify`, `rescue_plan`), `tests/system/rescue.xsh`, `tests/integration/fixtures/rescue-drill.xsh`, `guest/rescue-proof.xsh`
- **Problem:** `system.rescue` is imported only by its unit test and the rescue-drill fixture. The fixture's header says it runs through the same `system.rescue` contract the production decision uses, but no production module imports it and `guest/rescue-proof.xsh` does not use it, so the tested decision is not the one a rescued system runs. `RescueUnmounted` and `RescueReadOnly` are constructed only in tests.
- **Recommendation:** Either route the production rescue path through `system.rescue` and keep the drill, or delete the module and its tests and describe the actual rescue path. Decide which path is production first.
- **Fix with:** dead-code-archaeology
- **Effort:** S

### LAP-82 · P3 · Installer QEMU harnesses re-derive machine, CPU and kernel command line

- **Area:** System
- **Where:** `installer-qemu-test.xsh:12,226-258,276,283,476`, `installer-qemu-manual.xsh:4,16,32,38,76-100`, `system/qemu.xsh:79-81,95-135,150-151,165`, `system/image.xsh:14`, `installer/setup-laputa.xsh:15`
- **Problem:** AGENTS.md says `system/qemu.xsh` owns host QEMU mechanics, but both installer harnesses rebuild the per-arch machine, CPU, block, net and rng devices, the `QEMU_SYSTEM_*` lookup and the kernel command line body, and the root PARTUUID `33333333-...` is defined three times. A change to the boot command line or device set in `system/qemu.xsh` silently diverges from the installer proofs.
- **Recommendation:** Have the installer harnesses call `system/qemu.xsh` for the target table, executable lookup and command line, and define each root PARTUUID once.
- **Fix with:** single-source-of-truth
- **Effort:** M

### LAP-83 · P3 · Host XSH build features and rustflags are copied between Makefile and seed

- **Area:** Build
- **Where:** `Makefile:192-209`, `seed/xsh_seed.xsh:15-22,75-77`, `guest/self-hosting-build.xsh:24`, `Makefile:255-256`
- **Problem:** The host XSH feature set, the static-musl rustflags (including the `__isoc23_*` aliases) and the `xsh-test:<Dockerfile.test digest>` tag are written in both the Makefile and `seed/xsh_seed.xsh`, with a third copy of the rustflags in the self-hosting build. The Makefile's comments say to keep them identical; nothing checks it. The mirror's rust-toolchain pin carries the same unchecked rule.
- **Recommendation:** Make `seed/xsh_seed.xsh` the one owner and have the Makefile call it (or read its output) for the features, flags and tag; add a check for the toolchain pin.
- **Fix with:** single-source-of-truth
- **Effort:** S

### LAP-84 · P3 · make lint covers a third of the tree and gates nothing

- **Area:** Tooling
- **Where:** `Makefile:110-115`
- **Problem:** `make lint` runs `xsht lint` only on `pm.xsh pm system installer xinit`, so `guest/`, `seed/`, `trust/`, `xinfra/`, `profiles/`, the top-level scripts and `tests/` are never linted, and `make check` does not run it. Dead private code that xsht already flags (`guest/trust-guest.xsh:27 wait_for`, `guest/asterinas/device/entry.xsh:10 Node`) survived for that reason. Even that subset does not pass: on 2026-11-21 it reported 541 findings with the host xsht built from the pinned XSH and 654 with XSH master `aef945569` (`lint.redundant-propagation`, `unused-export` and `prefer-inferred-variant` lead), so `make lint` exits nonzero on every host, including a fresh newcomer capsule.
- **Recommendation:** Lint the whole workspace from `xsht-config.ini` (plain `xsht lint`) in `make lint`, and clear its findings. The subset cannot be made to pass honestly: `lint.unused-export` resolves references only within the files it is given, so on the subset it reports exports used by unlinted roots, such as `installer/host.xsh` `installer_env_path`, which `build-installer-common.xsh` imports; the workspace run does not. On 2026-11-22 the workspace run with XSH verification `xsht` reported 3,834 findings and 157 notes in 584 files (lint.redundant-propagation 1,407, prefer-inferred-variant 405, prefer-inferred-private-effects 217, pattern-conditional 185, prefer-guard 134, path-display-sink 133, redundant-default 107, default-param-type 78). Fixing them by hand is a multi-session campaign; `xsht lint --fix --only RULE` makes scoped, rechecked edits for the mechanical rules but is an autofixer, which needs the owner's permission. Acceptance: `make lint` runs the workspace lint and exits 0 on a fresh checkout.
- **Progress:** On 2026-11-22 the scoped `xsht lint --fix --only RULE` passes (owner-approved) and hand fixes cleared every workspace finding outside `packages/`; `xsht-config.ini` and `xinfra/xsht-config.ini` declare the interfaces and the five per-rule exclusions with their reasons (XSH-176). The 370 findings in `packages/` are fixed on `lane/lint-84-recipes`, held back because recipe edits rebuild the whole world; land that branch with the next planned world rebuild and switch `make lint` to plain `xsht lint` in the same change. On 2026-11-22 the owner approved that rebuild: the recipe fixes landed in `4a5731b9` and `make lint` now runs the workspace lint. The remaining 61 findings and ten shadowing errors were then cleared by hand: dead archive-plan, parser-generator and arm64-relink wrappers and their now-unused types were deleted, constants grouped before the first function, stale locals removed, and four entry-proc return annotations excluded in `xsht-config.ini` because `check.required-return` requires them. The network kernel is declared a public interface because its consumers are excluded system fixtures. Host tools were rebuilt from the approved XSH checkout after clearing stale cargo target artifacts. `make lint` reports 0 findings and 157 notes, and `make check` and `make test` pass; acceptance is met.
- **Fix with:** none
- **Effort:** S

### LAP-85 · P3 · Gluon consumer parity succeeds when reference builds fail

- **Area:** Tests
- **Where:** `gluon/tests/laputa/run.sh:48,60-73`, `gluon/tests/laputa/expected-fail`, `docs/DEVELOPMENT.md`
- **Problem:** The Laputa-owned consumer parity runner reports any reference setup, build or install failure as `SKIP` without setting its failure status. If the reference compiler or dependencies are broken for every selected package, the runner can exit zero without comparing any installed trees. The empty expected-fail ledger does not prevent this. GLU-32 covers the separate upstream fixture runner, not this consumer gate.
- **Recommendation:** Make failed reference stages fail the qualification run before consulting candidate-divergence allowances. If a diagnostic mode permits missing-prerequisite skips, report it as partial coverage and prevent it from satisfying the qualification gate. Account for selected and completed comparisons, reject a run with none completed, and retain the reference stage, exit status and logs in the result.
- **Fix with:** test-audit, reference-parity
- **Effort:** S
- **Acceptance:** Focused harness controls make reference setup, build and install fail independently and require a nonzero qualification result, including when every selected package fails or a candidate divergence is listed. A matching positive fixture passes, a differing installed tree fails, and an explicitly partial diagnostic run cannot be reported as qualified. Keep the fix in Laputa's consumer harness; shared Gluon semantics and fixtures remain upstream-owned.
