# TODO

Prefix: LAP
Next: 47

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

### LAP-6 · P2 · Verify shared bootstrap changes on aarch64

- **Area:** Tests
- **Where:** `docs/TESTING.md:45`
- **Problem:** The completed x86_64 bootstrap changed shared PM, musl, headers, installer, and profile paths without a full aarch64 world rebuild or boot proof. aarch64 parity is unproven.
- **Recommendation:** Run the clean world build and both installer and profile proofs on a native aarch64 host. Fix failures before claiming parity.
- **Deferred:** aarch64 qualification is deferred pending a macOS aarch64 host via Docker; no Linux aarch64 hardware is available. Retain this finding, but exclude it from active backlog runs until the owner reopens it.
- **Blocked:** This campaign has an x86_64 host; the required native aarch64 build and guest proof remain unavailable. Unblock with a macOS aarch64 host via Docker.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-7 · P2 · Capture foot while its proof window is alive

- **Area:** Tests
- **Where:** `system/qemu.xsh:263`, `guest/qemu-dwl-foot-proof.xsh:70`
- **Problem:** The host takes its screenshot after the success marker. The foot reader writes its input and exits before that marker, so screenshot presence does not prove visible terminal content.
- **Recommendation:** Keep the terminal alive until the host captures and checks its visual marker.
- **Progress:** The reader now waits after recording input, and the host requires a magenta marker before QEMU cleanup. A regression fails the old nonempty-screenshot acceptance and passes the repair; all 13 supervisor tests pass. Actual visual VM qualification remains blocked by the graphical package closure's Muon shell-execution boundary (LAP-14).
- **Fix with:** lifecycle-concurrency
- **Effort:** S (hours)

### LAP-33 · P2 · Qualify one confined extraction and publication path

- **Area:** Privileged filesystem boundaries
- **Where:** `pm/root.xsh`, `pm/store.xsh`, `pm/generation.xsh`, `trust/release.xsh`, `tests/pm/`
- **Problem:** These paths already have staging and validation defenses; retaining an opened trusted root through every relevant mutation has not been qualified. Lexical relative-path validation is not sufficient evidence against concurrent filesystem replacement.
- **Recommendation:** Trace one artifact-to-generation path end to end, reuse XSH-37's existing Root-backed operations where appropriate, and eliminate repeated check-then-open decisions. Specify symlink/hard-link and special-file policy, no-replace publication, cleanup ownership and the fsync boundary. Repair only demonstrated gaps before widening the audit.
- **Acceptance:** Malicious archive entries, ancestor/symlink swaps, destination conflicts, interrupted cleanup and full disks cannot alter outside sentinels or remove the prior committed generation. Record atomic-visibility and durability evidence separately; process-kill tests alone do not satisfy power-loss claims.
- **Blocked:** Frozen XSH exposes only Path-based archive extraction, no-replace rename and fsync. Scratch replacement probes demonstrate loss of opened-root authority on extraction/publication and a cleanup defect: closing a renamed temp-root handle removes an unowned replacement at its saved pathname. See [filesystem authority limits](docs/PM.md#filesystem-authority-limits) and its scratch-only reproducer. No power-loss durability is established.
- **Coordination:** Roadmap R4/R5; XSH-37 owns reusable host operations, not package policy.
- **Fix with:** isolate-effects
- **Effort:** M (days)

### LAP-14 · P3 · Remove redundant muon library lookup patches

- **Area:** Build
- **Where:** `packages/muon/PKGBUILD.xsh:51`, `packages/foot-minimal/PKGBUILD.xsh:152`, `packages/libinput/PKGBUILD.xsh:389`
- **Problem:** Recipes still replace find_library calls for musl aliases after muon gained linking by library name.
- **Recommendation:** Remove redundant replacements and rebuild the affected packages to check their links and DT_NEEDED entries.
- **Blocked:** The actual pinned Muon 0.7.0 rebuild routes embedded Samurai commands through `/bin/sh -c`. Removing the shell fails before affected package linkage can be qualified. Preserve the patches until the embedded executor carries structured argv without a POSIX shell; replacing it with a shell alias would violate the package-build contract.
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
- **Progress:** Typed IPv4 intent/ownership planning and bounded ordered replay pass nine native cases. A real read-only Docker veth capture reproduces the ownership conflict offline. Pure request encoding and strict read-only projection are tested. Independent review exposed a customized-route deletion hazard and an unobservable TOS selector. The unsafe live applier is withheld. The supplied XSH decoder drops rtmsg byte 3 entirely, so default-route identity and address-withdrawal safety cannot be qualified. XSH must expose TOS while preserving strict complete/interrupted/truncated dump checks; IPv6 remains separate. See [network policy](packages/laputa-net/README.md).
- **Fix with:** single-source-of-truth
- **Effort:** L (weeks)

### LAP-35 · P3 · Replace the QMP proof helper with a reusable XSH client

- **Area:** VM control
- **Where:** `boot/qmp-proof.py`, `system/qemu.xsh`, `tests/system/`, `docs/QEMU.md`
- **Problem:** QMP readiness/input/screenshot operations rely on a small Python helper. Translating it without a shared bounded protocol contract would only change the implementation language.
- **Recommendation:** Build a narrow XSH QMP library over XSH-39's qualified Unix-stream operations. Own greeting/capability negotiation, bounded JSON framing, request IDs, unsolicited events, deadlines and cleanup in XSH. Integrate the three current operations and delete the helper/dependency only after parity. Preserve LAP-21's non-retryable mutation boundary and the current Linux/macOS launch paths.
- **Acceptance:** Fragmented/coalesced messages, interleaved events, command errors, EOF and disconnect-after-send are deterministic local fixtures. Actual VM readiness/input/screenshot proofs pass without the Python helper. Unknown mutation outcomes are reported, not retried; retain LAP-7's independent visual-content requirement. No QMP-specific Rust intrinsic or new VM orchestration framework.
- **Blocked:** The supplied fixed XSH supports bounded fd I/O, polling and monotonic deadlines but lacks portable AF_UNIX connection setup. Existing socket/connect operations are Linux-only, so replacing the helper now would break the supported macOS path. See [QMP baseline](docs/QEMU.md#qmp-replacement-baseline).
- **Fix with:** deduplicate
- **Effort:** M (days)

### LAP-20 · P4 · Remove the libgcc_s compatibility name

- **Area:** Dependencies
- **Where:** `packages/gnu-stubs/PKGBUILD.xsh:83`
- **Problem:** gnu-stubs supplies libgcc_s from LLVM libunwind because the prebuilt Rust standard library requests that name.
- **Recommendation:** Retire the alias only with a Rust standard library built against LLVM libunwind and verified Rust package links.
- **Blocked:** The declared prebuilt Rust standard library still requires the compatibility name. A replacement SDK and its Cargo/package consumers need qualification before removal.
- **Fix with:** dead-code-archaeology
- **Effort:** L (weeks)

### LAP-39 · P4 · Measure the complexity delta of one removed glue boundary

- **Area:** Design economy
- **Where:** `docs/ROADMAP.md`, `docs/DEVELOPMENT.md`, `boot/qmp-proof.py`, `system/qemu.xsh`, `tests/system/`
- **Problem:** The roadmap already prescribes architectural subtraction, but no selected change measures first-party glue and invariants removed versus new dependencies and host boundaries created. A source-line quota or replacement of mature libraries would be counterproductive.
- **Recommendation:** Use LAP-35's Python QMP-helper replacement as one bounded case after its behavior proof. Record before/after entry points, argument/JSON round-trips, subprocesses, duplicate error rules, protocol ownership, first-party source, dependencies and verification cost. Relate the result to startup/binary measurements where XSH itself changes. Keep a compact evidence table in the owning docs, not a permanent scoring service or blanket LOC limit.
- **Acceptance:** A reviewer can trace every retired responsibility to an actual removal and every retained contract to tests; the new XSH QMP client passes the same fragmented-input and lifecycle cases. If replacement increases obligations without a demonstrated gain, retain or redesign it rather than claim simplification from language choice alone.
- **Progress:** The [QMP baseline](docs/QEMU.md#qmp-replacement-baseline) records current entry points, subprocesses, wire conversions, error owners, source/dependency cost and test obligations. The final comparison depends on LAP-35; no language-only simplification is claimed.
- **Coordination:** XSH-49 owns substrate-complexity accounting; LAP-35 owns the actual QMP implementation and evidence.
- **Fix with:** ultratriage
- **Effort:** S (hours)

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

### LAP-41 · P3 · Prove a trust-update key rotation end to end

- **Area:** Trust recovery
- **Where:** `trust/`, `packages/ca-certificates/`, `docs/CERTIFICATE-TRUST.md`
- **Problem:** The key ceremony documents rotation through an OS package update, but no test ships a new key plus new seeds, re-issues a release under it, and verifies the update path accepts the rotation while rejecting the old key's releases.
- **Recommendation:** Stage a rotated fixture key as a second package input, compose a release under it, and prove `trust update` converges while the superseded key's releases fail closed. Keep the rotation package-only; releases still carry no keys.
- **Progress:** `trust_update_rotates_keys_package_only` builds the rotated key and generation-4 seeds through `packages/ca-certificates` `build`, installs that payload, and shows `trust update` converge to generation 4 while releases signed by the superseded key fail closed. The release directory still has no key. Production `proof.xsh` still pins the shipped 118-certificate seed; the rotated seeds are fixture inputs, not a second production proof target.
- **Fix with:** reference-parity
- **Effort:** S (hours)

### LAP-42 · P3 · Track per-consumer enforcement of the distrust policy

- **Area:** Trust consumers
- **Where:** `docs/CERTIFICATE-TRUST.md`, `packages/uv/`, `packages/tailscale/`
- **Problem:** Sharing the canonical bundle does not prove a consumer enforces the intermediate-key blocklist. uv and Go-based Tailscale each carry their own verifier with distinct distrust behavior.
- **Recommendation:** Qualify each named consumer against the cross-signed fixture pair: blocked intermediate fails, unblocked control succeeds. Record the actual enforcement per consumer instead of assuming file sharing is proof.
- **Progress:** `tests/pm/trust_consumers.xsh` qualifies packaged uv 0.13.4 and tailscaled 1.104.2: control succeeds and the omitted-root chain fails, but the blocked-intermediate chain is accepted by both because neither reads the trust policy. Recorded in [per-consumer enforcement](docs/CERTIFICATE-TRUST.md#per-consumer-distrust-enforcement). Open: an enforcement mechanism (consumer patch, pinning, or removing the retained cross-signed root) is an owner decision.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-43 · P3 · Authenticate the package repository index

- **Area:** Repository trust
- **Where:** `pm/remote.xsh`, `docs/ROADMAP.md` (R4)
- **Problem:** Artifact hashes and mirror publisher authentication do not authenticate the mutable `index.json` to a client. The trust-release path signs trust inputs; repository metadata has no equivalent versioned, signed snapshot boundary.
- **Recommendation:** Add a versioned, signed release/snapshot boundary binding the exact index and referenced artifacts, with key provisioning, rotation/revocation, expiry, rollback/freeze handling, parser/size limits, and atomic publication. Compare an established update-metadata design before inventing a cryptographic protocol.
- **Progress:** `pm/repo_snapshot.xsh` adds the `laputa-repo-snapshot-v1` boundary reusing the trust-release verification shape (pinned key set with rotation window, 90-day expiry, accepted generation floor); `repo plan` from production remotes requires `XSH_PM_REPO_KEY_FILE` and fails closed, `repo publish-snapshot` publishes the offline-signed snapshot with the signature as linearization point. `file://` and loopback repositories are verified whenever `XSH_PM_REPO_KEY_FILE` is set, and accepted state is persisted atomically with fsync and refuses generation rollback. 19 snapshot tests plus the surrounding pm publish/plan/cli/graph suites pass. Remaining: manual key distribution (no package-seeded repo key), durable accepted state via `XSH_PM_REPO_STATE_DIR`, threshold/multi-signer snapshots, and guest proof of the production fetch path. See [PM snapshot authentication](docs/PM.md#snapshot-authentication).
- **Fix with:** architect
- **Effort:** L (weeks)

### LAP-44 · P1 · Prove maintained first boot on a fresh VM

- **Area:** Identity and access
- **Where:** `system/first_boot.xsh`, `profiles/qemu-maintained.xsh`, `packages/dropbear/`, `packages/nftables/`
- **Problem:** The long-lived profile is distinct in source, but no VM has booted it, rebooted it, or shown that a bad ruleset leaves the listener down.
- **Recommendation:** Boot `qemu-maintained` from a first-boot document, reboot, and confirm the Dropbear host key and operator files are unchanged. Confirm a missing or rejected `/etc/nftables.conf` does not start Dropbear. Keep the SSH client in XSH-55.
- **Progress:** `qemu-maintained` sets `development` false. The other profiles set it true and keep their roots, including autologin in the installer. First-boot documents are rejected before any write. A new operator takes the next free id at or above 1000, a locked shadow entry, and `/usr/bin/xsh` in `/etc/shells` when those files exist. Dropbear uses `/etc/dropbear/dropbear_ed25519_host_key` and creates it only when absent; `XINIT_DROPBEAR_EPHEMERAL=1` is the only `-R` path. The nftables package installs `/etc/nftables.conf`. The firewall oneshot runs `nft -f` once and fails when the file is absent or nft returns non-zero. Ten first-boot tests, seven profile tests, and an xinit check of firewall, dropbear-keygen, and dropbear pass. The ruleset was not rebuilt into an image. A crash during apply can leave a partial tree. Test-mode self-hosting cmdline also carries `LAPUTA_SELF_HOSTING_PROOF=1`; the guest script still requires `LAPUTA_SELF_HOSTING=1`.
- **Fix with:** security
- **Effort:** M (days)

### LAP-45 · P1 · Restore a detached disk from an independent rescue boot

- **Area:** Storage repair
- **Where:** `packages/e2fsprogs/`, `system/rescue.xsh`, `docs/INSTALLER.md`
- **Problem:** Classification and a launch fragment do not show that a broken guest can be repaired without its own network, package manager, or XSH.
- **Recommendation:** Build a rescue image that contains `e2fsck`, attach a disposable dirty ext disk, and boot it with serial and no network. Record clean, repaired, and unrecoverable results, including file hashes after a repair.
- **Progress:** `e2fsprogs` 1.47.2 installs only `usr/bin/e2fsck` for x86_64, built with the package task graph and no shell. The package build printed `e2fsprogs ok: e2fsck -V`. `fsck.ext4` stays the superblock checker. `rescue_repair_argv` is `e2fsck -f -p` for an unmounted or read-only device and errors for a writable mount. Exit 0 is clean, 1 and 2 are repaired, 4 and 8 are unrecoverable, and any other status is failed. `rescue_plan` attaches a read-only rescue image and the detached disk on virtio with serial and no network; a comma or whitespace in either path is rejected. The plan does not boot the image. Four rescue tests pass.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-46 · P1 · Select the fallback generation from the host launcher

- **Area:** Activation
- **Where:** `system/activation.xsh`, `system/launcher.xsh`, `system/qemu.xsh`
- **Problem:** The activation record can fall back in a host-side test, but the launcher still boots whatever disk it was given.
- **Recommendation:** Have the direct-kernel launcher read the record, boot the pending generation, and fall back after the recorded attempt limit. Keep the guest from rolling itself back. Do not put this in a package script.
- **Progress:** `system/activation.xsh` installs a receipt, stages a candidate without changing current, begins a boot, confirms health only for the pending id, and clears a pending boot after two failures while current stays on the fallback. The lock is an exclusive `fs.mknod`, and record writes are temp file, fsync, rename, directory fsync. Ten activation tests pass. `system/launcher.xsh` selects that record for a direct-kernel argv: current with no write, the pending generation after `{output}/generations/images/{id}/kernel` and `disk` exist, and the fallback image once `boot_attempts` reaches the cap. The id must be one path segment. A comma or whitespace in a host path is rejected. `laputa boot` uses this selection when `{output}/generations/activation.json` exists and otherwise keeps the profile image. The launcher does not confirm health and does not start QEMU. Seven launcher tests pass. No guest reboot has been run.
- **Fix with:** durable-state
- **Effort:** M (days)
