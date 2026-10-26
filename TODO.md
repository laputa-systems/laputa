# TODO

Prefix: LAP
Next: 36

Open work from package-manager development, the local bootstrap, and the
XSH/Laputa systems-foundation review. Priorities are assumed from impact;
verification gaps are marked unproven. [Roadmap](docs/ROADMAP.md) owns direction
and milestone sequencing; this file owns bounded implementation slices.

Apply the roadmap's design filter: keep policy in ordinary XSH, reuse narrow
host operations, and remove duplicated responsibilities rather than growing
parallel managers or frameworks. [XSH's queue](https://github.com/laputa-systems/xsh/blob/master/TODO.md)
owns shared substrate changes; peer IDs below identify coordination, not authority
to modify another checkout. Review baselines: Laputa `85c175515312`, XSH
`9d893e0075d2`. No new runtime proof follows from this documentation update.

Real-hardware enablement remains out of scope. Existing hardware entries are
retained but deferred as noted below. VM clocks, virtual networking, disposable
disks and native build hosts remain in scope. Existing paused campaigns are not
resumed. Choose a bounded slice and its acceptance tests; do not launch this
entire queue as a new campaign.

### LAP-5 · P2 · Make service configuration strict and typed

- **Area:** Config
- **Where:** `xinit/xinit.xsh::service_from_record`, `packages/*/service.xsh`, `xinit/tests/`, `xinit/docs/INIT.md`
- **Problem:** Unknown fields silently take defaults; `log` is ignored when `logging` is present. Validation and normalization need one authoritative service contract instead of new per-format parsers or schemas.
- **Recommendation:** First reject unknown top-level/nested keys and conflicting settings. Then consolidate the existing service model into one checked specification, retaining documented defaults and hook behavior. Separate shape validation, dependency/resource-policy checks and execution preconditions. Expose normalized redacted configuration and a read-only start plan with useful source/default/override provenance where layering exists. Keep trusted executable service modules distinct from external data; loading a module is not inert parsing.
- **Acceptance:** Invalid names, variants, ranges, dependencies and missing/null fields fail before service application. Check/plan does not launch services or mutate runtime state. Every installed/generated service passes `xinit check`; invalid fixtures identify the field and origin. Reuse XSH's canonical validation for any decoded data, not a schema DSL. The immediate rejection fix does not wait for Deser; later data-consumer proof coordinates with XSH-41.
- **Fix with:** make-invalid-states-unrepresentable
- **Effort:** M (days)

### LAP-6 · P2 · Verify shared bootstrap changes on aarch64

- **Area:** Tests
- **Where:** `docs/TESTING.md:45`
- **Problem:** The completed x86_64 bootstrap changed shared PM, musl, headers, installer, and profile paths without a full aarch64 world rebuild or boot proof. aarch64 parity is unproven.
- **Recommendation:** Run the clean world build and both installer and profile proofs on a native aarch64 host. Fix failures before claiming parity.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-7 · P2 · Capture foot while its proof window is alive

- **Area:** Tests
- **Where:** `system/qemu.xsh:263`, `guest/qemu-dwl-foot-proof.xsh:70`
- **Problem:** The host takes its screenshot after the success marker. The foot reader writes its input and exits before that marker, so screenshot presence does not prove visible terminal content.
- **Recommendation:** Keep the terminal alive until the host captures and checks its visual marker.
- **Fix with:** lifecycle-concurrency
- **Effort:** S (hours)

### LAP-27 · P2 · Move xinit elapsed deadlines off wall time

- **Area:** Lifecycle
- **Where:** `xinit/xinit.xsh`, `xinit/tests/`, `seed/verify.xsh`, `pm/execute.xsh`
- **Problem:** xinit uses `time.now()` for readiness/backoff deadlines; PM/build measurements also use wall time. Clock correction can change elapsed comparisons. Runtime consequences on the current guest are unproven; XSH monotonic time also has different units and a process-local origin.
- **Recommendation:** Audit these consumers and migrate elapsed budgets through XSH-35's explicit clock contract, starting with xinit. Keep calendar timestamps, trust expiry and synchronization state separate. Define scanner restart and VM pause behavior rather than persisting process-local deadlines or mechanically swapping function names.
- **Acceptance:** Controlled clock inputs and disposable guests with forward/backward wall jumps preserve readiness, restart and stop budgets without busy loops or unbounded waits. Test unit conversion and restart/pause recovery. NTP synchronization is not service readiness; tests never alter the build host's clock.
- **Coordination:** Roadmap R1/R2; XSH-35 owns shared clock semantics.
- **Fix with:** lifecycle-concurrency
- **Effort:** M (days)

### LAP-28 · P2 · Prove a closed build environment for a small package cohort

- **Area:** Build authority
- **Where:** `pm/env.xsh`, `pm/execute.xsh`, `system/docker.xsh`, `seed/`, `Dockerfile.package-tools`
- **Problem:** Build paths prepend declared tools to ambient paths and package-tools retains an external host-tools base. These are bootstrap choices, not a demonstrated escape, but offline execution alone does not establish a closed input or authority boundary.
- **Recommendation:** Select a small C/Rust/XSH-build cohort. Declare executable/library/source/environment inputs, seed exceptions, writable output/scratch roots, inherited descriptors and network policy. Qualify a restricted build path using existing execution infrastructure with OS enforcement, not only an effect annotation, PATH filter or lexical path check. Keep exceptions explicit; no second sandbox/deployment framework.
- **Acceptance:** Undeclared tools, libraries, environment and reads/writes outside the allowed closure are rejected or unavailable. Poison ambient inputs and verify sentinels; declared builds still pass offline. Record the exact trusted host/seed boundary and unsupported enforcement. LAP-10 compares payloads; reproducible output alone is not isolation proof.
- **Fix with:** isolate-effects
- **Effort:** M (days)

### LAP-31 · P2 · Test executor changes against artifact-cache validity

- **Area:** Build identity
- **Where:** `pm/plan.xsh`, `pm/fingerprint.xsh`, `pm/policy.xsh`, `tests/pm/`, `docs/PM.md`
- **Problem:** Executor identity is provenance rather than an artifact-key input; payload-affecting interpreter/PM changes rely on explicit BUILD_EPOCH or recipe invalidation. Content addressing cannot by itself detect a changed recipe meaning.
- **Recommendation:** Specify the semantic invalidation contract and owner. Require payload-affecting changes to invalidate/reject reuse through the existing epoch/revision mechanism or a justified narrower compatibility identity. Preserve intentional reuse for non-affecting edits; do not make every interpreter commit rebuild the world or imply automatic semantic-change detection.
- **Acceptance:** Paired executor fixtures show intentional same-contract reuse and explicit invalidation for a changed payload contract; saved plans at an incompatible epoch are rejected. Tests and author guidance expose the required invalidation step. Coordinate LAP-10/LAP-28; do not replace independent rebuild comparisons with identity assertions.
- **Fix with:** single-source-of-truth
- **Effort:** M (days)

### LAP-33 · P2 · Qualify one confined extraction and publication path

- **Area:** Privileged filesystem boundaries
- **Where:** `pm/root.xsh`, `pm/store.xsh`, `pm/generation.xsh`, `trust/release.xsh`, `tests/pm/`
- **Problem:** These paths already have staging and validation defenses; retaining an opened trusted root through every relevant mutation has not been qualified. Lexical relative-path validation is not sufficient evidence against concurrent filesystem replacement.
- **Recommendation:** Trace one artifact-to-generation path end to end, reuse XSH-37's existing Root-backed operations where appropriate, and eliminate repeated check-then-open decisions. Specify symlink/hard-link and special-file policy, no-replace publication, cleanup ownership and the fsync boundary. Repair only demonstrated gaps before widening the audit.
- **Acceptance:** Malicious archive entries, ancestor/symlink swaps, destination conflicts, interrupted cleanup and full disks cannot alter outside sentinels or remove the prior committed generation. Record atomic-visibility and durability evidence separately; process-kill tests alone do not satisfy power-loss claims.
- **Coordination:** Roadmap R4/R5; XSH-37 owns reusable host operations, not package policy.
- **Fix with:** isolate-effects
- **Effort:** M (days)

### LAP-1 · P3 · Attach package context at the execution boundary

- **Area:** Errors
- **Where:** `pm/execute.xsh:244`
- **Problem:** PM error messages repeat package names manually instead of using one package execution context.
- **Recommendation:** Wrap each package build and proof in `ctx`, then remove repeated package prefixes where the context supplies them.
- **Fix with:** error-model
- **Effort:** M (days)

### LAP-2 · P3 · Use Target instead of recipe architecture strings

- **Area:** Types
- **Where:** `pm/types.xsh:31`, `pm/target.xsh:1`
- **Problem:** Recipes compare architecture strings and often treat the other branch as x86_64. Adding a target cannot expose those assumptions through exhaustive matching.
- **Recommendation:** Match the existing Target enum at recipe architecture boundaries.
- **Fix with:** make-invalid-states-unrepresentable
- **Effort:** M (days)

### LAP-3 · P3 · Update recipe filetrees from a built payload

- **Area:** Build
- **Where:** `pm/cli.xsh:1`, `pm/recipe.xsh:222`
- **Problem:** Maintainers hand-edit filetrees one undeclared-output failure at a time.
- **Recommendation:** Add `pm repo update-filetree PKG` to produce a reviewable diff from the last verified payload.
- **Fix with:** none
- **Effort:** M (days)

### LAP-4 · P3 · Infer repeated recipe defaults

- **Area:** Config
- **Where:** `pm/recipe.xsh:292`
- **Problem:** Recipes repeat their directory name, payload kind, initial release, and architecture-neutral source declarations.
- **Recommendation:** Resolve these defaults at recipe loading and lint redundant declarations without changing existing package identity.
- **Fix with:** single-source-of-truth
- **Effort:** M (days)

### LAP-8 · P3 · Give shared upstream pins one owner

- **Area:** Dependencies
- **Where:** `packages/cargo/PKGBUILD.xsh:25`, `packages/sudo-rs/PKGBUILD.xsh:85`, `packages/linux/PKGBUILD.xsh:47`, `packages/linux-headers/PKGBUILD.xsh:26`, `packages/perf/PKGBUILD.xsh:48`
- **Problem:** The Rust distribution date and kernel source pin each occur in multiple recipes, allowing dependent inputs to drift.
- **Recommendation:** Define each shared pin once and keep target checksums in the same declaration.
- **Fix with:** single-source-of-truth
- **Effort:** S (hours)

### LAP-9 · P3 · Separate proof dependencies from build dependencies

- **Area:** Build
- **Where:** `packages/man-pages/PKGBUILD.xsh:21`, `pm/execute.xsh:208`
- **Problem:** man-pages needs mandoc for validation but declares it as a build dependency, so proof tooling enters payload identity.
- **Recommendation:** Add a distinct proof dependency contract and compose proof roots from it without changing payload keys.
- **Fix with:** durable-state
- **Effort:** M (days)

### LAP-10 · P3 · Check package payload reproducibility

- **Area:** Tests
- **Where:** `pm/store.xsh:1`, `pm/fingerprint.xsh:1`
- **Problem:** Artifact keys describe inputs, but the bootstrap proof does not independently rebuild and compare payloads.
- **Recommendation:** Rebuild selected artifacts in isolated stores and compare payload digests for the same keys. Use LAP-28's closed cohort and vary checkout location, HOME, locale, timezone and undeclared tools/libraries. Record exact executor/toolchain inputs and explain mismatches rather than blessing new hashes. LAP-31 owns semantic executor invalidation; stable keys alone establish neither reproducibility nor hermeticity.
- **Acceptance:** Independent builds match payload bytes and required metadata under the documented normalization policy; poisoned ambient inputs are ignored or rejected. Publish per-target evidence, not inferred cross-architecture parity.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-11 · P3 · Detect kernel configuration drift

- **Area:** Build
- **Where:** `packages/linux/files/config/x86_64/base-x86_64.fragment:1`, `packages/linux/files/config/aarch64/base-aarch64.fragment:1`
- **Problem:** Config fragments have no check against the pinned kernel Kconfig after upgrades. The earlier x86_64 normalization does not prevent later drift.
- **Recommendation:** Compare each fragment with olddefconfig output using the pinned compiler and report changed symbols.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-12 · P3 · Report available package updates

- **Area:** Operability
- **Where:** `pm/cli.xsh:1`
- **Problem:** PM can update source checksums but has no outdated command to report newer package releases.
- **Recommendation:** Add `pm repo outdated` with explicit upstream version sources and visible lookup failures.
- **Fix with:** none
- **Effort:** M (days)

### LAP-13 · P3 · Build the manual-page index during composition

- **Area:** Operability
- **Where:** `pm/root.xsh:1`, `packages/mandoc/PKGBUILD.xsh:1`
- **Problem:** The package set contains manual pages and mandoc, but root composition does not build a makewhatis index.
- **Recommendation:** Define when a composed root needs the index and generate it from that root's pages.
- **Fix with:** none
- **Effort:** S (hours)

### LAP-14 · P3 · Remove redundant muon library lookup patches

- **Area:** Build
- **Where:** `packages/muon/PKGBUILD.xsh:51`, `packages/foot-minimal/PKGBUILD.xsh:152`, `packages/libinput/PKGBUILD.xsh:389`
- **Problem:** Recipes still replace find_library calls for musl aliases after muon gained linking by library name.
- **Recommendation:** Remove redundant replacements and rebuild the affected packages to check their links and DT_NEEDED entries.
- **Fix with:** delete
- **Effort:** M (days)

### LAP-15 · P3 · Ship USB IDs used by libudev-zero

- **Deferred:** Real-hardware work is outside the roadmap. Retain this finding, but exclude it from active backlog runs until the owner reopens it.
- **Area:** Dependencies
- **Where:** `packages/libudev-zero/PKGBUILD.xsh:76`, `packages/hwdata/PKGBUILD.xsh:39`
- **Problem:** libudev-zero looks for `/usr/share/hwdata/usb.ids`, but hwdata installs PCI and PNP databases only. USB vendor and product names remain unset.
- **Recommendation:** Package the USB database and declare the runtime dependency that supplies it.
- **Fix with:** single-source-of-truth
- **Effort:** S (hours)

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
- **Fix with:** none
- **Effort:** S (hours)

### LAP-18 · P3 · Evaluate in-world parser generation

- **Area:** Build
- **Where:** `packages/mesa/files/generated/README.md:1`, `packages/perf/PKGBUILD.xsh:26`
- **Problem:** Mesa and perf retain generated parser and lexer inputs. The bootstrap established working bison and flex, but interpreted m4 makes large grammars expensive.
- **Recommendation:** Measure representative generation before choosing faster m4 or retaining vendored outputs. Keep Python-generated Mesa inputs vendored.
- **Fix with:** make-it-fast
- **Effort:** M (days)

### LAP-19 · P3 · Verify the reported XSH debug-driver stack failure

- **Area:** Build
- **Where:** `../xsh/dev/main.xsh:1`
- **Problem:** The campaign reported `cargo dev --help` overflowing an 8 MB stack while release builds worked. This external-checkout finding is unproven on the current XSH revision.
- **Recommendation:** Reproduce in the XSH checkout and fix the stack use if it persists.
- **Fix with:** root-cause
- **Effort:** M (days)

### LAP-21 · P3 · Make non-idempotent QMP requests unretryable by type

- **Area:** Types
- **Where:** `system/qemu.xsh:178`, `system/qemu.xsh:188`
- **Problem:** `qemu_qmp_retry` must carry only idempotent readiness and screenshot requests, because a retried keyboard injection can duplicate the proof keystrokes. `mode` is a `Str`, so the constraint was held only by a comment, now deleted.
- **Recommendation:** Give the retried modes their own closed type so keyboard input cannot reach `qemu_qmp_retry`. Preserve this boundary in LAP-35's native client; a disconnected command with an unknown outcome must not be blindly replayed.
- **Acceptance:** A negative type/dispatch fixture excludes input injection from the retry path; a disconnect-after-send test emits it at most once and reports an indeterminate outcome.
- **Fix with:** make-invalid-states-unrepresentable
- **Effort:** S (hours)

### LAP-22 · P3 · Confirm xinit test switches leave production behavior unchanged

- **Area:** Architecture
- **Where:** `xinit/xinit.xsh:374`, `xinit/xinit.xsh:804`, `xinit/xinit.xsh:944`, `xinit/xinit.xsh:1057`
- **Problem:** `XSH_UNIX_DRY_RUN` skips the status liveness reconcile, selects the cgroup path, and bypasses scanner detection. The inittab respawn delay and launch limit read only from `XSH_INIT_TEST_*` variables. `run_pid1` accepts both `XINIT_TEST_ALLOW_NON_PID1` and `XSH_INIT_TEST_ALLOW_NON_PID1`. The repo invariant says test-only switches must not change production behavior. `XSH_INIT_FAST_SHUTDOWN` and `XSH_INIT_FINAL_CLEANUP` are not named as test switches. Unproven: whether any production run sets them.
- **Recommendation:** Keep one name for the non-PID1 switch. Move the respawn delay and limit into typed inittab configuration. Show that each remaining switch is inert unless a test sets it.
- **Fix with:** isolate-effects
- **Effort:** M (days)

### LAP-23 · P3 · Delete remaining non-contract comments in XSH sources

- **Area:** Navigability
- **Where:** `pm/execute.xsh:1`, `pm/sources.xsh:1`, `xinit/tests/xinit.xsh:1`, `packages/m4/files/m4.xsh:1`, `packages/tic/files/tic.xsh:1`
- **Problem:** Tracked `.xsh` files still hold about 2,960 line comments outside doc comments, generated inputs included. `xinit/xinit.xsh` and `system/qemu.xsh` are clean. Comments that explain our own code go stale and get copied.
- **Recommendation:** Delete each comment per `comment-cleanup`, fix the causes behind any excuse, and move rationale into the doc that owns the topic. Skip generated files and external-quirk comments.
- **Fix with:** comment-cleanup
- **Effort:** L (weeks)

### LAP-29 · P3 · Build and run a replacement XSH inside Laputa

- **Area:** Self-hosting
- **Where:** `packages/xsh/PKGBUILD.xsh`, `packages/cargo/`, `seed/`, `profiles/`, `tests/integration/`
- **Problem:** The xsh package imports externally built seed products instead of compiling XSH in the package world. A self-hosted replacement is not established by verifying those imported bytes.
- **Recommendation:** After LAP-28's closed cohort, build the pinned Rust XSH implementation inside a Linux Laputa guest using declared source, toolchain and crate inputs. Keep bootstrap compilers/seeds explicit; this is distribution self-hosting, not rewriting the compiler in XSH or eliminating every seed. Run the resulting xsh/xsht and use them to rebuild the selected cohort without ambient host executables.
- **Acceptance:** Saved inputs produce runnable replacement tools and focused language/host proofs inside the guest; the replacement rebuilds the cohort. Record provenance and payload comparisons under LAP-10/LAP-31. Start with one target and mark other architecture/Asterinas results unverified; no claim of a complete self-hosted world.
- **Fix with:** reference-parity
- **Effort:** L (weeks)

### LAP-30 · P3 · Build and boot one successor generation with in-guest tools

- **Area:** System integration
- **Where:** `seed/`, `system/`, `profiles/`, `guest/`, `tests/integration/`
- **Problem:** The host can compose and boot bundles, but the in-guest replacement toolchain has not closed the build-successor-boot loop.
- **Recommendation:** After LAP-29, use its tools to build the selected successor package closure and compose a matching kernel/root bundle through PM. Let the existing launcher boot it and have the guest report its actual generation/overlay identity. An explicit local-development proof can precede production R4/R5 activation; do not invent live PID 1 replacement or a new VM manager.
- **Acceptance:** Boot A, produce B using A's declared in-guest tools, boot B, and verify the expected running receipt plus focused behavior. Detect mixed kernel/root or stale receipts and preserve A on failure. This milestone does not itself close authenticated delivery, automatic rollback or complete-world reproducibility.
- **Coordination:** Roadmap R10; R4/R5 own production trust/activation and state policy.
- **Fix with:** reference-parity
- **Effort:** L (weeks)

### LAP-32 · P3 · Reconcile one managed virtual interface through a typed plan

- **Area:** Network policy
- **Where:** `packages/laputa-net/`, `profiles/`, `tests/system/`, `tests/integration/`
- **Problem:** One-shot interface setup does not provide an inspectable ownership-aware change plan or recovery from partial application. Replacing it with a larger opaque daemon would not exercise reusable XSH policy.
- **Recommendation:** Use XSH-38 for one virtual-Ethernet links/addresses/routes cohort. Write observation, pure planning and application/re-observation in XSH. Track owned resources separately from Tailscale/operator state; check stale preconditions and resynchronize after lost notifications. Coordinate resolver ownership and the maintained lease client under R2 rather than building a DHCP stack or universal provider framework.
- **Acceptance:** A no-change plan mutates nothing; reapplication converges; foreign addresses/routes survive; injected stale observations, failed operations and lost events lead to explicit conflict/re-observation, not fictitious rollback. The read-only plan is redacted and inspectable. Qualify IPv4/IPv6 separately on disposable VMs; physical networking stays excluded.
- **Fix with:** single-source-of-truth
- **Effort:** L (weeks)

### LAP-34 · P3 · Connect one VM lifecycle failure to a reduced native replay

- **Area:** Tests
- **Where:** `xinit/tests/`, `tests/system/`, `tests/integration/`, `guest/`, `system/qemu.xsh`
- **Problem:** Native fixtures and VM proofs exist, but a minimized failure crossing both layers is not established. More success markers would not prove lifecycle invariants.
- **Recommendation:** Start with one service spawn/readiness/crash/stop counterexample using the canonical supervised path. Capture only the boundary observations needed by XSH-40 and reduce the sequence to a hermetic native test. Reuse ordinary test entry points and existing guest control. Extend the method to network/publication only after this slice proves useful.
- **Acceptance:** The native regression and real guest both expose the original invariant failure and reject a deliberately broken repair. Missing replay data cannot hit the live host; records are bounded and secret-redacted. Verify no duplicate service or surviving owned child after recovery. Process termination is not a storage power-loss test; R3/R5 require independent disk-failure qualification.
- **Coordination:** XSH-36/XSH-40; preserve separate Linux/Asterinas evidence and LAP-22's production/test boundary.
- **Fix with:** root-cause
- **Effort:** M (days)

### LAP-35 · P3 · Replace the QMP proof helper with a reusable XSH client

- **Area:** VM control
- **Where:** `boot/qmp-proof.py`, `system/qemu.xsh`, `tests/system/`, `docs/QEMU.md`
- **Problem:** QMP readiness/input/screenshot operations rely on a small Python helper. Translating it without a shared bounded protocol contract would only change the implementation language.
- **Recommendation:** Build a narrow XSH QMP library over XSH-39's qualified Unix-stream operations. Own greeting/capability negotiation, bounded JSON framing, request IDs, unsolicited events, deadlines and cleanup in XSH. Integrate the three current operations and delete the helper/dependency only after parity. Preserve LAP-21's non-retryable mutation boundary and the current Linux/macOS launch paths.
- **Acceptance:** Fragmented/coalesced messages, interleaved events, command errors, EOF and disconnect-after-send are deterministic local fixtures. Actual VM readiness/input/screenshot proofs pass without the Python helper. Unknown mutation outcomes are reported, not retried; retain LAP-7's independent visual-content requirement. No QMP-specific Rust intrinsic or new VM orchestration framework.
- **Fix with:** deduplicate
- **Effort:** M (days)

### LAP-20 · P4 · Remove the libgcc_s compatibility name

- **Area:** Dependencies
- **Where:** `packages/gnu-stubs/PKGBUILD.xsh:83`
- **Problem:** gnu-stubs supplies libgcc_s from LLVM libunwind because the prebuilt Rust standard library requests that name.
- **Recommendation:** Retire the alias only with a Rust standard library built against LLVM libunwind and verified Rust package links.
- **Fix with:** dead-code-archaeology
- **Effort:** L (weeks)

### LAP-24 · P4 · Set the module path in the manual installer target

- **Area:** Build
- **Where:** `Makefile:393`
- **Problem:** `installer-qemu-manual` passes neither `XSH_MODULE_PATH` nor `LAPUTA_REPO_URL`, so the README tells users to export `XSH_MODULE_PATH` by hand, unlike `installer-image` and `installer-qemu-test`.
- **Recommendation:** Pass the same variables as the sibling targets, then drop the manual export from `README.md`.
- **Fix with:** single-source-of-truth
- **Effort:** S (hours)

### LAP-25 · P4 · Share the installer build environment record

- **Area:** Navigability
- **Where:** `installer-qemu-test.xsh:426`, `installer-qemu-manual.xsh:52`
- **Problem:** Both scripts build the same `build_env` record twice, with and without `KERNEL_SOURCE`, and can drift apart.
- **Recommendation:** Build the record once in the shared installer host module.
- **Fix with:** deduplicate
- **Effort:** S (hours)

### LAP-26 · P4 · Document or retire undocumented make targets

- **Area:** Docs
- **Where:** `Makefile:100`
- **Problem:** `mirror-demo`, `mirror-frontend`, `fetch-mirror`, `mirror-build-x86_64-musl`, and `deploy-mirror-fresh` appear in no doc, apart from a mention of `deploy-mirror-fresh` in `docs/MIRROR-DEPLOYMENT.md`.
- **Recommendation:** Describe each target in its owning doc, or delete the unused ones.
- **Fix with:** dead-code-archaeology
- **Effort:** S (hours)
