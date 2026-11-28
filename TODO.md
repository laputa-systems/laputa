Prefix: LAP
Next: 103

Open work from package-manager development, the local bootstrap, and the
XSH/Laputa systems-foundation review. Priorities are assumed from impact;
verification gaps are marked unproven. [Roadmap](docs/roadmap.md) owns direction
and milestone sequencing; this file owns bounded implementation slices.

Apply the roadmap's design filter: keep policy in ordinary XSH, reuse narrow
host operations, and remove duplicated responsibilities rather than growing
parallel managers or frameworks. [XSH's queue](https://github.com/laputa-systems/xsh/blob/master/TODO.md)
owns shared substrate changes; peer IDs below identify coordination, not authority
to modify another checkout. Owning topic documents record qualified behavior
and its remaining limits.

### LAP-80 · P2 · xinit's non-PID1 test opt-in changes control-plane authorization

- **Area:** Init
- **Where:** `xinit/xinit.xsh:137-139` (`test_mode`), `:252-269` (`control_group_gid`, `control_owner_uid`, `control_sender_permitted`), `:2385` (`scan_units` calls `unix.pid1_setup(..., allow_non_pid1: true)` ungated), `xinit/docs/INIT.md:115-135`
- **Problem:** AGENTS.md requires that xinit test-only switches not change production behavior, and INIT.md says `XINIT_TEST_ALLOW_NON_PID1` enables test controls only. In code it also replaces the control-plane authorization: with the opt-in set and pid not 1, the control group is the run directory's gid instead of `xinit-admin`, the owner uid is the euid instead of 0, and any sender with the same euid is permitted. The gate is `pid != 1`, which holds for the scanner and every `xinit VERB` client, not only for fixtures. `scan_units` passes `allow_non_pid1: true` with no gate at all. The scanner inherits PID 1's environment, so no exploit was shown, but the invariant the guide states is not the one the code keeps.
- **Recommendation:** Make the authorization functions independent of test mode and give fixtures a real `xinit-admin` group (or an injected owner and group in the fixture harness). Gate `scan_units`' `allow_non_pid1` on test mode, and add a test that a non-PID1 production scanner rejects a sender outside `xinit-admin` with the opt-in set.
- **Fix with:** security, isolate-effects
- **Effort:** M

### LAP-87 · P2 · The musl regcomp and GB18030 backports are unproven on aarch64

- **Area:** Security
- **Where:** `packages/musl/PKGBUILD.xsh` (patches `musl-regcomp-int-overflow.patch` from musl 7813e911 and `musl-gb18030-iconv-decoder.patch` from 67219f01, `rel = "17"`); `packages/musl/proof.xsh`
- **Problem:** Both CVE backports (CVE-2026-107891, CVE-2026-6042) are applied for every architecture and proven on x86_64: the GB18030 regression programs fail on unpatched 1.2.6 and pass patched, and the regcomp family passes patched. The regcomp overflow itself was not triggered, since it needs about 2^31 positions. The aarch64 musl build and the cross-compile of the proof programs have not run, because the x86_64 host has no aarch64 seed.
- **Recommendation:** On the aarch64 host, run `make seed` and `make build PKGS=musl` and record the proof result here before closing.
- **Fix with:** none
- **Effort:** S

### LAP-89 · P2 · A readiness timeout satisfies a required dependency

- **Area:** Supervision
- **Where:** `xinit/xinit.xsh:1834-1847` (`gate_satisfied`), `xinit/docs/INIT.md:245-252`, `xinit/docs/SUPERVISION.md:56`
- **Problem:** When a unit's `ready()` hook or notify byte does not arrive within `ready_timeout_ms`, the unit becomes `running` with `ready` false. `gate_satisfied` checks only `state == "running"` for `dependencies.need`, so a service that never became ready releases its dependents, which then start against a service that has said it cannot serve. The docs describe the promotion but not that it satisfies `need`. unproven: whether `need` is meant to require readiness is an owner decision.
- **Recommendation:** Decide the contract. Either make `need` wait for `ready` and report a timed-out dependency as blocking, or state in INIT.md that `need` gates only on the process running and add a separate readiness-gated dependency kind. Add lifecycle tests where a needed service times out unready, and where a required provider fails while its consumer is starting: the consumer must never be reported initialized.
- **Fix with:** lifecycle-concurrency, error-model
- **Effort:** S

### LAP-91 · P2 · musl regcomp overflows the C stack on long literal patterns

- **Area:** Security
- **Where:** `packages/musl/PKGBUILD.xsh` (musl 1.2.6 `src/regex/regcomp.c`, TRE's recursive parse and position passes)
- **Problem:** `regcomp()` on a pattern of 200,000 literal `a` characters (`REG_EXTENDED|REG_NOSUB`) segfaults under an 8 MiB stack with unpatched musl 1.2.6; 100,000 and 150,000 compile, and 300,000 returns `REG_ESPACE`. Upstream commit 7813e911 (the LAP-87 regcomp overflow fix) raises the stack limit, so with it 300,000 also segfaults. A program that compiles an untrusted regex can be crashed rather than handed an error. Reproduced on 2026-11-23 with static test programs linked against both builds; the recursing function was not identified, and both cases compile under `ulimit -s unlimited`.
- **Recommendation:** Find the recursing pass, bound its depth so oversized patterns fail with `REG_ESPACE`, and carry it as a checksum-bound patch in a `laputa-systems` musl fork with an upstream draft. Keep a child-process regression for each length above.
- **Fix with:** security, os-boundaries
- **Effort:** M

### LAP-92 · P2 · zlib-rs crashes or corrupts output on four paths zlib 1.4 handles safely

- **Area:** Security
- **Where:** `packages/zlib-rs/PKGBUILD.xsh`; `qualification/zlib-rs/differential.c` (known-divergence table); `docs/NATIVE-CENSUS.md` (zlib-rs differential); LAP-51 Track C
- **Problem:** Against the zlib 1.4 oracle, zlib-rs segfaults when `gzwrite` writes a large buffer into a full nonblocking pipe (the CVE-2026-85091 path), aborts on repeated `deflatePrime` with memLevel 1, returns stale window bytes from `inflateBack` on corrupt streams (23 of 600 random and 216 of 600 mutated inputs), and, after a stalled `gzwrite`, stops writing or leaves more bytes in the file than it accepted (80,000 bytes after accepting 60,000 with flushes). The differential records each as a known divergence, so it passes. No shipped profile links zlib-rs today, so this blocks Track C's replacement of C zlib rather than exposing a running system. Found 2026-11-23 by the LAP-88 qualification on x86_64.
- **Recommendation:** Fix each in a `laputa-systems` zlib-rs fork with an upstream draft, add the reproducing input to the differential as a required match, and remove its known-divergence entry. Track C must not ship zlib-rs while any of the four remain.
- **Fix with:** security
- **Effort:** M

### LAP-94 · P2 · Seed host-tools still installs build-base instead of the owned clang

- **Area:** Build images / OT7
- **Where:** `seed/Dockerfile.host-tools:8`; `Dockerfile.package-tools` (the `test -x /usr/bin/cc` gate); `seed/images.lock`; `docs/DEVELOPMENT.md` "Rebuilding and repinning build images"
- **Problem:** `owned-tool-substitution` flags `build-base` in the host-tools Dockerfile as duplicating laputa-systems/llvm-prebuilt-musl. These are pinned bootstrap inputs: `seed/images.lock` records each published digest plus `dockerfile_sha256`, and package-tools refuses to build without `/usr/bin/cc`, which build-base currently supplies. Removing build-base without providing `cc` breaks the offline package-tools image, and changing the Dockerfile makes the lock stale until both architectures are rebuilt and repinned.
- **Recommendation:** Copy `/opt/laputa` from the pinned owned-tools image into host-tools (the doas-rs pattern), keep a `cc` symlink to the owned clang, and keep `e2fsprogs`, `util-linux` and the other Alpine tools. For x86_64 and aarch64, build both layouts with `xsh seed/images.xsh -- build --arch ARCH --seed-root PATH --sources PATH`, publish host-tools and package-tools to `oci.17166969.xyz/laputa-host-tools` and `oci.17166969.xyz/laputa-package-tools`, record the published digests and the new `dockerfile_sha256` in `seed/images.lock`, then recompute `package_key_ARCH` with `xsh seed/images.xsh -- key --arch ARCH`. Verify `repomod lint --rule owned-tool-substitution` is clean for laputa and that `make fetch`/`seed-smoke` still pass on both architectures. Publication was approved by the owner on 2026-11-26; the work was deferred then and laputa is out of the Owned-tools-first campaign scope until this ticket is done.
- **Fix with:** none
- **Effort:** L

### LAP-101 · P2 · musl floatscan writes before its mantissa buffer; merged fix not backported

- **Area:** Security
- **Where:** `packages/musl/PKGBUILD.xsh` (1.2.6, patch loop applies only `musl-regcomp-int-overflow.patch` and `musl-gb18030-iconv-decoder.patch`); musl 1.2.6 `src/internal/floatscan.c:259` (`decfloat`), `src/network/resolvconf.c`, `src/network/res_msend.c`; upstream commits `dd856098ad76451718161f864158a38157d8b871` (2026-09-22) and `897937236ddbbf07ef41749a88812c594e5f69b4` (2026-09-07)
- **Problem:** `decfloat` advances its circular mantissa index and stores in one expression; when the index wraps to zero it stores a zero at index -1, one word before the buffer. Upstream confirms triggering inputs for 80-bit (x86_64) and binary128 (aarch64) long double, so both Laputa targets are affected through `strtod`/`strtold`/`scanf`. Separately, `attempts:0` in resolv.conf makes `res_msend` divide by zero. Both fixes are merged upstream and absent from the package. unproven: no deployed Laputa service is shown to parse attacker-controlled floats or to receive `attempts:0`.
- **Recommendation:** Backport both upstream commits as checksum-bound patches beside the existing two. Add to the musl package proof: the upstream floatscan reproducer under a sanitizer-instrumented reference build, bit-exact results and end pointers for that input and neighbouring rounding boundaries in the packaged libc, and a resolver run with `attempts:0` that fails bounded without terminating while normal retries still work. Qualify x86_64 and aarch64 separately, as for LAP-87.
- **Fix with:** none
- **Effort:** S

### LAP-16 · P3 · Exercise sound and wireless device support

- **Area:** Tests
- **Where:** `system/qemu.xsh:1`, `packages/linux/files/config/aarch64/base-aarch64.fragment:1879`
- **Problem:** The graphical proof covers neither sound nor wireless devices. WLAN is disabled in the kernel fragments, and QEMU does not exercise the installed audio tools.
- **Recommendation:** Choose a supported device path, enable its kernel support, and verify the matching userspace against it.
- **Fix with:** reference-parity
- **Effort:** M

### LAP-20 · P3 · Fork the Rust toolchain build to retire gnu-stubs

- **Area:** Dependencies
- **Where:** `packages/gnu-stubs/PKGBUILD.xsh`, `packages/cargo/PKGBUILD.xsh`
- **Problem:** Laputa-built Rust packages no longer load libgcc_s.so.1: the cc wrapper links LLVM's static libunwind.a for `-static-libgcc`. Play 0.42.2 links its GCC runtime statically. One consumer still needs gnu-stubs at run time: the prebuilt upstream `cargo`, `rustc`, `rustdoc`, `rust-lld`, `rust-analyzer-proc-macro-srv` and `libstd-*.so` from static.rust-lang.org import `_Unwind_*` from libgcc_s.so.1, and Laputa cannot relink them. Builds also take gnu-stubs' empty crtbeginS.o and crtendS.o from cargo's closure.
- **Recommendation:** Fork the Rust toolchain build under laputa-systems and build cargo, rustc and the musl std from source against Laputa's musl with the `llvm-libunwind` std feature, so nothing imports libgcc_s. Retire libgcc_s.so.1 and the crt stubs once no recipe or prebuilt input needs them. Acceptance: No package's installed ELF files carry a libgcc_s NEEDED entry or a GCC runtime import, the PM ELF check reports no gnu-stubs provider, and Rust packages still build and pass their proofs with the source-built toolchain. Parked: The prebuilt `cargo`, `rustdoc`, `librustc_driver`, `libstd`, `rust-lld` and helper tools import libgcc_s; `rustc` does not. A source-built `cargo` needs an OpenSSL-compatible TLS library for curl, libgit2 and libssh2, and Laputa ships none: the routes are curl's rustls backend (needs `rustls-ffi`, which the rust source does not vendor, and drops ssh git), AWS-LC through `openssl-sys`, or a `cargo` without network TLS. Each adds work or a native dependency the owner does not want now, so gnu-stubs stays. The prebuilt 1.99.0 works as stage0 and Laputa's LLVM 23.1.5 as the external LLVM. The cargo proof skips its runtime check when `libgcc_s.so.1` is absent, so it must become a real run once gnu-stubs leaves its closure.
- **Fix with:** reference-parity, dead-code-archaeology
- **Effort:** L

### LAP-52 · P3 · Share rust-fontconfig across Ghostty and Play

- **Area:** Dependencies
- **Where:** `packages/`, `docs/FONT-STACK.md`, `../ghostty/src/font/`, `../play/rust/player-overlay/src/text/linux.rs`
- **Problem:** The canonical graphical stack still relies on C Fontconfig and Expat. Upstream rust-fontconfig has not been qualified as a shared discovery provider for both consumers.
- **Recommendation:** After the shared native font stack and Play SRT/Core Text migrations pass, package pinned upstream rust-fontconfig as one versioned musl shared library. Adapt both consumers to its C API, retain shared FreeType and HarfBuzz, and qualify configuration, caching, fallback, rendered output, ABI, closure, and measured costs before removing the native provider. Acceptance: Both applications dynamically resolve the same Laputa library. International discovery and cluster-safe fallback pass real rendering and guest proofs. Native Fontconfig and unused Expat leave the canonical graphical closure. Preserve macOS and existing security gates. Report exact upstream and repository revisions, SONAME, features, results, and installed footprint. Evidence: See [shared font stack](docs/FONT-STACK.md#final-composed-root); aarch64 guest and macOS runs remain deferred.
- **Fix with:** architect, reference-parity, benchmark-checklist
- **Effort:** L
- **Design:** [Shared upstream rust-fontconfig](docs/rfc/LAP-52-rust-fontconfig.md)

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
- **Recommendation:** Lint the whole workspace from `xsht-config.ini` (plain `xsht lint`) in `make lint`, and clear its findings. The subset cannot be made to pass honestly: `lint.unused-export` resolves references only within the files it is given, so on the subset it reports exports used by unlinted roots, such as `installer/host.xsh` `installer_env_path`, which `build-installer-common.xsh` imports; the workspace run does not. On 2026-11-22 the workspace run with XSH verification `xsht` reported 3,834 findings and 157 notes in 584 files (lint.redundant-propagation 1,407, prefer-inferred-variant 405, prefer-inferred-private-effects 217, pattern-conditional 185, prefer-guard 134, path-display-sink 133, redundant-default 107, default-param-type 78). Fixing them by hand is a multi-session campaign; `xsht lint --fix --only RULE` makes scoped, rechecked edits for the mechanical rules but is an autofixer, which needs the owner's permission. Acceptance: `make lint` runs the workspace lint and exits 0 on a fresh checkout. Resolution: The owner-approved changes landed in `4a5731b9`, `519e0c8` and `d23d763`; `make lint` reported 0 findings and 157 notes, and `make check` and `make test` passed.
- **Fix with:** none
- **Effort:** S

### LAP-85 · P3 · Gluon consumer parity succeeds when reference builds fail

- **Area:** Tests
- **Where:** `gluon/tests/laputa/run.sh:48,60-73`, `gluon/tests/laputa/expected-fail`, `docs/DEVELOPMENT.md`
- **Problem:** The Laputa-owned consumer parity runner reports any reference setup, build or install failure as `SKIP` without setting its failure status. If the reference compiler or dependencies are broken for every selected package, the runner can exit zero without comparing any installed trees. The empty expected-fail ledger does not prevent this. GLU-32 covers the separate upstream fixture runner, not this consumer gate.
- **Recommendation:** Make failed reference stages fail the qualification run before consulting candidate-divergence allowances. If a diagnostic mode permits missing-prerequisite skips, report it as partial coverage and prevent it from satisfying the qualification gate. Account for selected and completed comparisons, reject a run with none completed, and retain the reference stage, exit status and logs in the result. Acceptance: Focused harness controls make reference setup, build and install fail independently and require a nonzero qualification result, including when every selected package fails or a candidate divergence is listed. A matching positive fixture passes, a differing installed tree fails, and an explicitly partial diagnostic run cannot be reported as qualified. Keep the fix in Laputa's consumer harness; shared Gluon semantics and fixtures remain upstream-owned.
- **Fix with:** test-audit, reference-parity
- **Effort:** S

### LAP-86 · P3 · Asterinas rejects malformed trailing netlink attributes that Linux ignores

- **Area:** Asterinas fork · netlink
- **Where:** `asterinas/kernel/core/src/net/socket/netlink/message/attr/mod.rs` (`AttrValidation::LegacyChange`), `asterinas/test/initramfs/src/regression/network/rtnl_ack.c:114`
- **Problem:** A legacy (non-strict) `RTM_NEWADDR` whose last attribute overruns the message gets `EINVAL` on Asterinas. Linux parses these requests with `NL_VALIDATE_LIBERAL`, warns about the leftover bytes and applies the attributes before them. The fork chose the stricter answer in `12249b0fe` and marked the `rtnl_ack` case Asterinas-only. Upstream's 2026 netlink framework had moved Asterinas to the Linux behavior; the 2026-11-21 rebase restored the fork's divergence with `LegacyChange` so the witness keeps passing.
- **Recommendation:** Once the Linux backend can run again, record Linux's reply for the three malformed-attribute requests in `rtnl_ack` on both backends. If Linux acknowledges them, drop `LegacyChange`, change the case to expect the Linux reply (deleting the address it creates), and run it on both backends. Acceptance: `qualify.sh all --backend both` passes `network/rtnl_ack` with the malformed-attribute case run on both backends and the same result on each.
- **Fix with:** reference-parity
- **Effort:** S

### LAP-88 · P3 · zlib 1.4 is unverified on aarch64

- **Area:** Security
- **Where:** `packages/zlib/PKGBUILD.xsh` (`ver = "1.4"`, architecture-neutral CMake build); `docs/NATIVE-CENSUS.md` (zlib gate evidence)
- **Problem:** The C zlib reference is 1.4 and the x86_64 consumers (FreeType, libpng, mandoc, Play, `build-essential-native`) build and pass their proofs against it; the zlib-rs differential now uses it as oracle. The aarch64 build and proof of zlib 1.4 and of its consumers have not run: the host is x86_64 and `docs/DEVELOPMENT.md` says cross-architecture builds are unsupported. unproven: the aarch64 build, `zlib ok`, and `xsh qualification/zlib-rs/run.xsh -- aarch64`.
- **Recommendation:** When an aarch64 build is supported, build and prove `zlib`, `libpng`, `freetype` and `mandoc` on aarch64 and run the zlib-rs gate there, then delete this item.
- **Fix with:** security
- **Effort:** S

### LAP-90 · P3 · laputa-net always depends on wpa_supplicant

- **Area:** Closure
- **Where:** `packages/laputa-net/PKGBUILD.xsh:24-25` (`runtime_only_deps = ["wpa_supplicant", "xinit", "xsh"]`)
- **Problem:** Every root that installs laputa-net also installs wpa_supplicant, including `qemu-maintained`, whose virtio networking never associates with Wi-Fi. Wireless is outside the maintained VM scope (LAP-16), so the dependency adds closure, attack surface and build cost with no consumer in those profiles.
- **Recommendation:** Make wpa_supplicant a profile-selected dependency of the wireless path only, and check that the maintained QEMU roots no longer contain it while a wireless-enabled profile still does.
- **Fix with:** api-surface-and-module-boundaries
- **Effort:** S

### LAP-93 · P3 · PM publication durability is proven only against process kill

- **Area:** Package manager
- **Where:** `docs/PM.md` (filesystem authority limits, lines 713–731); PM artifact publication and verification entry points; QEMU guest qualification harness
- **Problem:** The PM contract fsyncs staged files and directories, publishes with a no-replace rename and fsyncs the destination parent, but the evidence is `strace` ordering plus process-kill recovery, which proves atomic visibility, not that the store survives a failed write, a failed flush or lost volatile writes. A missed or misordered sync would pass every current test.
- **Recommendation:** For one artifact-publication transaction on a disposable ext4 store, inject write and flush failures with QEMU `blkdebug` (`write_aio`, `flush_to_os`, `flush_to_disk`) at each sync and rename boundary, and require that every recovered store holds either the complete verifiable artifact or no admitted artifact, keeps any prior valid artifact and lets interrupted staging be reclaimed. `blkdebug` proves error handling only, not ordering under lost volatile writes, so the negative control that drops one required sync must be detected through Linux `dm-log-writes` replay, which follows the error-injection pass. Extend to activation records and the trust floor only after both pass. Both stay host-side; nothing enters the installed generation.
- **Fix with:** none
- **Effort:** M

### LAP-95 · P3 · e2fsck 1.47.2 is qualified only by its version banner

- **Area:** System
- **Where:** `packages/e2fsprogs/PKGBUILD.xsh` (`ver = "1.47.2"`), `packages/e2fsprogs/proof.xsh`, `system/rescue.xsh`; upstream v1.47.4 `tests/f_ea_inode_fast_symlink`, `tests/f_ea_zero_size`, `tests/f_ea_inode_disconnected`
- **Problem:** The rescue checker is pinned at 1.47.2 and its package proof checks ELF compatibility and `-V` only. 1.47.2 wrongly reports a valid fast symlink with a large external xattr as corrupt, and does not check zero-sized external xattrs; 1.47.4 fixes both. A repair tool that modifies a valid filesystem is itself a recovery risk, and the rescue guest corruption cases do not cover these shapes.
- **Recommendation:** Bump to 1.47.4, revalidating the vendored generated headers and source inventory. Import the three upstream fixture images and expected outcomes into development qualification, not the rescue image: run the packaged e2fsck on fresh copies, require `f_ea_inode_fast_symlink` to stay clean with status 0 on both passes and the two damaged images to repair (status 1) then check clean. Qualify the production `-f -p` invocation separately from upstream test options. Keep the existing rescue guest proofs.
- **Fix with:** none
- **Effort:** M

### LAP-96 · P3 · Three upstream musl correctness fixes are unapplied in 1.2.6

- **Area:** Security
- **Where:** `packages/musl/PKGBUILD.xsh` (`ver = "1.2.6"`); musl `src/passwd/getspnam_r.c` (`xatol`), `src/stdio/getdelim.c:74`, `src/time/__tz.c:262-322` (`scan_trans`); musl list threads of 2026-11-23 (getdelim), 2026-11-25 (shadow overflow), 2026-11-26 (single-transition TZif)
- **Problem:** (1) The shadow parser accumulates numeric aging fields into a signed long without overflow checks: undefined behaviour and wrong values on oversized fields. doas-rs reads only `sp_pwdp`, so no authentication impact is shown. (2) `getdelim` compares high-bit delimiters (128-255) wrongly on its unbuffered path where `char` is signed. (3) For TZif files with exactly one transition, `scan_trans` takes the last-transition branch before the pre-transition branch, so timestamps before the transition get the footer rule instead of the initial type (RFC 9636). Real zones have this shape, for example Africa/Abidjan and America/Anguilla. All three patches were still under list review when filed.
- **Recommendation:** When each patch is final upstream, backport it beside the existing musl backports with a regression in the musl package proof: `fgetspent` on valid, empty, maximal, overflowing and malformed fields; a buffered-versus-unbuffered `getdelim` comparison with a high-bit delimiter; `localtime_r` before, at and after the transition for every single-transition file in the packaged tzdata tree against an independent reference, with multi-transition zones as controls. Qualify on both architectures as for LAP-87.
- **Fix with:** none
- **Effort:** M

### LAP-97 · P3 · Builds are not tested against directory enumeration order

- **Area:** Package manager
- **Where:** `pm/catalog.xsh`, `pm/fingerprint.xsh`, `pm/payload_archive.xsh`, `docs/SELF-HOSTING.md`
- **Problem:** PM sorts in its catalog and fingerprint paths, but nothing shows that package generators, compiler input inventories or archive construction are independent of filesystem readdir order. A hidden order dependency would make artifacts differ between hosts from identical inputs without any check noticing.
- **Recommendation:** In the existing independent-rebuild qualification, build one small C package and one XSH-generated package twice from identical pinned inputs under disorderfs, once sorted and once reverse-sorted, with separate output stores. First confirm the enumeration actually differs, then require equal artifact identity, payload digest and archive bytes. Include a deliberately order-dependent generator as a negative control that must be detected. disorderfs stays host-side test tooling only.
- **Fix with:** none
- **Effort:** M

### LAP-99 · P3 · A compromised signing key can exhaust the snapshot generation floor

- **Area:** Security
- **Where:** `pm/repo_snapshot.xsh:154-182`, `docs/PM.md:462-515`, `tests/integration/fixtures/repo-snapshot-publish.xsh`
- **Problem:** Clients persist the highest accepted generation and key rotation never resets that floor, by design. A holder of a trusted key can publish a valid snapshot at an extreme generation; after revocation clients still hold that floor, so normal publication by the replacement key cannot advance and only out-of-band recovery restores updates. This is a documented trust-model limitation, but no test demonstrates it or pins the operator recovery boundary.
- **Recommendation:** Add a signed-snapshot fixture test: accept a normal generation, accept an extreme valid generation, revoke the key, show that a normal generation from the replacement key is rejected, and record the exact operator recovery step in PM.md. Do not weaken rollback protection. If in-band recovery becomes a requirement, write an RFC for an authenticated repository epoch.
- **Fix with:** none
- **Effort:** S

### LAP-100 · P3 · xinit lacks restart and shutdown race lifecycle tests

- **Area:** Supervision
- **Where:** `xinit/xinit.xsh`, `xinit/tests/`, `xinit/docs/INIT.md:245-263`, `xinit/docs/SUPERVISION.md`; Dinit v0.23.0 NEWS
- **Problem:** Dinit 0.23.0 fixed duplicate-start, shutdown-ordering and restart-after-dependency-failure bugs found by its expanded tests. xinit has no recorded tests for the equivalent races, so the same defects could exist unnoticed: a provider restarting under an operational consumer, a stop request overlapping a scheduled restart, and shutdown while units are starting or in backoff.
- **Recommendation:** Compare existing xinit coverage, then add lifecycle tests: a provider restart after the consumer is up keeps the no-blanket-cascade policy deterministic; a stop overlapping a scheduled restart leaves no duplicate instance; shutdown with units starting or in backoff reaps every owned process before filesystem shutdown. Keep the notify-byte framing and do not import failure propagation.
- **Fix with:** lifecycle-concurrency
- **Effort:** M

### LAP-102 · P3 · libc float parsing has no independent bit-exact corpus

- **Area:** Tests
- **Where:** `packages/musl/proof.xsh`; external corpus `github.com/nigeltao/parse-number-fxx-test-data` (Apache-2.0)
- **Problem:** The musl proof and libc-test check selected cases, but nothing compares `strtof`/`strtod` against independent expected bit patterns at scale. The parse-number-fxx corpus (over five million inputs with expected binary16/32/64 bits) is where the musl decfloat out-of-bounds store was found, so it demonstrably finds real libc defects. It has no binary80 or binary128 expectations, and its expected values come from Go's parser.
- **Recommendation:** Pin a corpus revision and select a subset covering hard decimal representations, subnormals, rounding ties, and overflow and underflow boundaries. A small C test linked against the packaged musl compares resulting bits, not formatted output, and runs in development qualification only. Keep libc-test. Classify any unsupported semantics explicitly.
- **Fix with:** none
- **Effort:** M

### LAP-98 · P4 · pkgconf compiles libpkgconf twice with no known library consumer

- **Area:** Build
- **Where:** `packages/pkgconf/PKGBUILD.xsh:177-310`, `packages/pkgconf/proof.xsh`
- **Problem:** The recipe builds the 21 libpkgconf sources once shared and once static, installs both libraries plus headers and .pc metadata, and links four tools (pkgconf, bomtool, spdxtool, pccritic). A search of Laputa sources found no direct libpkgconf consumer beyond the recipe and its ABI proof, so the SDK and the duplicate compile may be dead build work. Build time only; the maintained profiles exclude pkgconf.
- **Recommendation:** Inventory libpkgconf and extra-tool consumers across fetched sources and native dependencies. If there are none, compare a full-featured CLI-only build (not `Makefile.lite`, which changes sysroot and static-link semantics) against the current recipe on compile count, CPU time and output bytes, gated by the existing sysroot, private-dependency and static-link proof plus representative Mesa, Wayland and HarfBuzz builds. Consider importing upstream pkgconf fixture tests into the proof.
- **Fix with:** none
- **Effort:** S

