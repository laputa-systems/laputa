# TODO

Prefix: LAP
Next: 21

Open work from package-manager development and the completed local bootstrap.
Priorities are assumed from impact. Verification gaps are marked unproven.

### LAP-5 · P2 · Reject unknown service fields

- **Area:** Config
- **Where:** `xinit/xinit.xsh:516`
- **Problem:** `service_from_record` reads recognized keys without rejecting extra keys, so a misspelled service setting silently takes its default.
- **Recommendation:** Validate keys at the top level and in nested sections. Add a failing check for a misspelled setting.
- **Fix with:** make-invalid-states-unrepresentable
- **Effort:** S (hours)

### LAP-6 · P2 · Verify shared bootstrap changes on aarch64

- **Area:** Tests
- **Where:** `docs/TESTING.md:45`
- **Problem:** The completed x86_64 bootstrap changed shared PM, musl, headers, installer, and profile paths without a full aarch64 world rebuild or boot proof. aarch64 parity is unproven.
- **Recommendation:** Run the clean world build and both installer and profile proofs on a native aarch64 host. Fix failures before claiming parity.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-7 · P2 · Capture foot while its proof window is alive

- **Area:** Tests
- **Where:** `system/qemu.xsh:280`, `guest/qemu-dwl-foot-proof.xsh:70`
- **Problem:** The host takes its screenshot after the success marker. The foot reader writes its input and exits before that marker, so screenshot presence does not prove visible terminal content.
- **Recommendation:** Keep the terminal alive until the host captures and checks its visual marker.
- **Fix with:** lifecycle-concurrency
- **Effort:** S (hours)

### LAP-1 · P3 · Attach package context at the execution boundary

- **Area:** Errors
- **Where:** `pm/execute.xsh:244`
- **Problem:** PM error messages repeat package names manually instead of using one package execution context.
- **Recommendation:** Wrap each package build and proof in `ctx`, then remove repeated package prefixes where the context supplies them.
- **Fix with:** error-model
- **Effort:** M (days)

### LAP-2 · P3 · Use Target instead of recipe architecture strings

- **Area:** Types
- **Where:** `pm/types.xsh:1`, `pm/target.xsh:1`
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
- **Recommendation:** Rebuild selected artifacts in isolated stores and compare payload digests for the same keys.
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

- **Area:** Dependencies
- **Where:** `packages/libudev-zero/PKGBUILD.xsh:76`, `packages/hwdata/PKGBUILD.xsh:39`
- **Problem:** libudev-zero looks for `/usr/share/hwdata/usb.ids`, but hwdata installs PCI and PNP databases only. USB vendor and product names remain unset.
- **Recommendation:** Package the USB database and declare the runtime dependency that supplies it.
- **Fix with:** single-source-of-truth
- **Effort:** S (hours)

### LAP-16 · P3 · Exercise sound and wireless device support

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

### LAP-20 · P4 · Remove the libgcc_s compatibility name

- **Area:** Dependencies
- **Where:** `packages/gnu-stubs/PKGBUILD.xsh:75`
- **Problem:** gnu-stubs supplies libgcc_s from LLVM libunwind because the prebuilt Rust standard library requests that name.
- **Recommendation:** Retire the alias only with a Rust standard library built against LLVM libunwind and verified Rust package links.
- **Fix with:** dead-code-archaeology
- **Effort:** L (weeks)
