# TODO

Prefix: LAP
Next: 49

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

All performance work is deferred by the owner, including readiness checks and
time, memory, binary-size and scaling measurements. Functional work continues.

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
- **Blocked:** Frozen XSH exposes only Path-based archive extraction, no-replace rename and fsync. Scratch replacement probes still show loss of opened-root authority on extraction/publication; the cleanup case fails closed on current XSH (close errors "moved or replaced; left in place", both trees retained) instead of deleting the replacement, and its fixture now asserts that outcome. No power-loss durability is established.
- **Coordination:** Roadmap R4/R5; XSH-37 owns reusable host operations, not package policy.
- **Fix with:** isolate-effects
- **Effort:** M (days)

### LAP-15 · P3 · Ship USB IDs used by libudev-zero
- **Area:** Dependencies
- **Where:** `packages/libudev-zero/PKGBUILD.xsh:76`, `packages/hwdata/PKGBUILD.xsh:39`
- **Problem:** libudev-zero looks for `/usr/share/hwdata/usb.ids`, but hwdata installs PCI and PNP databases only. USB vendor and product names remain unset.
- **Recommendation:** Package the USB database and declare the runtime dependency that supplies it.
- **Progress:** hwdata installs `usb.ids` and libudev-zero depends on hwdata. Package proofs check vendor/product data in the composed runtime closure; removing the dependency fails the proof. The x86_64 package rebuild passes. This packages identification data without enabling physical hardware.
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
- **Progress:** Typed IPv4 intent/ownership planning and bounded ordered replay pass nine native cases. A real read-only Docker veth capture reproduces the ownership conflict offline. Pure request encoding and strict read-only projection are tested. Independent review exposed a customized-route deletion hazard and an unobservable TOS selector. The unsafe live applier is withheld. The XSH side of the TOS gap is now closed in this checkout: `linux.network_dump` parses rtmsg byte 3 and exposes typed integer `tos` on route records, with decoder unit tests distinguishing TOS 0 from 8 and truncated headers still rejected. The Laputa side now consumes it: `network_project_dump` projects only ordinary TOS-0 main-table unicast defaults carrying the encoder's own attributes into `NetworkDefaultRoute`, refuses TOS-specific or customized selected defaults explicitly (even beside an ordinary default), ignores defaults on other links, and the capture driver rejects non-zero TOS. Thirteen kernel-projection cases pass. `network_project_stable_dumps` requires two identical consecutive complete dumps, and the capture driver's TOS rejection is tested offline through the pure `select_capture`. `linux.network_dump` already guarantees per-dump `NLMSG_DONE`, `NLM_F_DUMP_INTR` retry-then-issue and truncation issues; its four dumps carry no shared kernel generation. The live applier stays withheld pending guest and shared-boundary qualification of the coordinated XSH API (below); IPv6 stays separate.
- **XSH coordination:** `linux.netlink_route_request` now provides the bounded request/acknowledgement primitive with sequence/port validation, a deadline, and rejection of malformed or multipart replies. `network-policy-guest.xsh` consumes its errno record rather than treating a kernel refusal as a transport error; source checking and the eleven offline policy tests pass. A Linux x86_64/KVM guest built through the canonical seed path from clean XSH `8dfb48d07` confirms address ACK errno 0 and route refusal errno 101 as data, with partial and foreign address state retained. No real transport failure was induced; live-applier and convergence qualification remain open. Cross-dump atomicity would additionally need `linux.network_dump` to expose a single route-netlink generation, or to take all four dumps under one sequence-checked interruption flag. Not attempted here. See [network policy](packages/laputa-net/README.md).
- **Fix with:** single-source-of-truth
- **Effort:** L (weeks)

### LAP-35 · P3 · Replace the QMP proof helper with a reusable XSH client

- **Area:** VM control
- **Where:** `system/qmp.xsh`, `system/qemu.xsh`, `tests/system/`, `docs/QEMU.md`
- **Problem:** QMP readiness/input/screenshot operations rely on a small Python helper. Translating it without a shared bounded protocol contract would only change the implementation language.
- **Recommendation:** Build a narrow XSH QMP library over XSH-39's qualified Unix-stream operations. Own greeting/capability negotiation, bounded JSON framing, request IDs, unsolicited events, deadlines and cleanup in XSH. Integrate the three current operations and delete the helper/dependency only after parity. Preserve LAP-21's non-retryable mutation boundary and the current Linux/macOS launch paths.
- **Acceptance:** Fragmented/coalesced messages, interleaved events, command errors, EOF and disconnect-after-send are deterministic local fixtures. Actual VM readiness/input/screenshot proofs pass without the Python helper. Unknown mutation outcomes are reported, not retried; retain LAP-7's independent visual-content requirement. No QMP-specific Rust intrinsic or new VM orchestration framework.
- **Progress:** Both supported host paths use `system/qmp.xsh` over portable `unix.connect_stream` for readiness, input, VT switching, screenshots and pause/resume. The client bounds frames, matches response IDs, handles events, reports uncertain outcomes and shares the supervisor's monotonic deadline. The Python helper and transport selector are deleted. Fifteen native peer cases, fourteen supervisor cases and the final Linux x86_64/KVM graphical proof pass with the qualified static SDK. No macOS or aarch64 runtime qualification is claimed. See [QMP baseline](docs/QEMU.md#qmp-replacement-baseline).
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
- **Where:** `docs/ROADMAP.md`, `docs/DEVELOPMENT.md`, `system/qmp.xsh`, `system/qemu.xsh`, `tests/system/`
- **Problem:** The roadmap already prescribes architectural subtraction, but no selected change measures first-party glue and invariants removed versus new dependencies and host boundaries created. A source-line quota or replacement of mature libraries would be counterproductive.
- **Recommendation:** Use LAP-35's Python QMP-helper replacement as one bounded case after its behavior proof. Record before/after entry points, argument/JSON round-trips, subprocesses, duplicate error rules, protocol ownership, first-party source, dependencies and verification cost. Relate the result to startup/binary measurements where XSH itself changes. Keep a compact evidence table in the owning docs, not a permanent scoring service or blanket LOC limit.
- **Acceptance:** A reviewer can trace every retired responsibility to an actual removal and every retained contract to tests; the new XSH QMP client passes the same fragmented-input and lifecycle cases. If replacement increases obligations without a demonstrated gain, retain or redesign it rather than claim simplification from language choice alone.
- **Progress:** The [QMP baseline](docs/QEMU.md#qmp-replacement-baseline) compares the retired helper with the native client: no QMP subprocesses or argv crossing, one protocol owner, explicit reusable socket substrate cost, and preserved failure and visual-proof contracts. Laputa client/supervisor source is 615 lines versus 645 before replacement. This excludes XSH's added socket implementation and makes no global source-size or speed claim.
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
- **Progress:** `trust_update_rotates_keys_package_only` builds the rotated key and generation-4 seeds through `packages/ca-certificates` `build`, installs that payload, and shows `trust update` converge to generation 4 while releases signed by the superseded key fail closed. All 36 trust-update cases pass. The release directory still has no key. Production `proof.xsh` still pins the shipped 118-certificate seed; the rotated seeds are fixture inputs, not a second production proof target.
- **Fix with:** reference-parity
- **Effort:** S (hours)

### LAP-42 · P3 · Track per-consumer enforcement of the distrust policy

- **Area:** Trust consumers
- **Where:** `docs/CERTIFICATE-TRUST.md`, `packages/uv/`, `packages/tailscale/`
- **Problem:** Sharing the canonical bundle does not prove a consumer enforces the intermediate-key blocklist. uv and Go-based Tailscale each carry their own verifier with distinct distrust behavior.
- **Recommendation:** Qualify each named consumer against the cross-signed fixture pair: blocked intermediate fails, unblocked control succeeds. Record the actual enforcement per consumer instead of assuming file sharing is proof.
- **Progress:** Source-built Tailscale 1.104.2 enforces the canonical SPKI policy while retaining the root bundle. Real TLS fixtures reject both cross-signed forms and accept the unblocked control. XSH and Tailscale reject insecure incomplete-chain bypasses when policy is installed. Tailscale checks fresh and resumed handshakes, preserves system and extra control roots, and refuses policy deletion after observation. uv deliberately retains the checksum-pinned upstream prebuilt binary: it enforces root omission but accepts the blocked intermediate under a retained root. Its characterization remains in `tests/pm/trust_consumers.xsh`. See [per-consumer enforcement](docs/CERTIFICATE-TRUST.md#per-consumer-distrust-enforcement) for lifecycle limits and the remaining uv enforcement gap.
- **Fix with:** reference-parity
- **Effort:** M (days)

### LAP-43 · P0 · Authenticate the package repository index

- **Area:** Repository trust
- **Where:** `pm/remote.xsh`, `docs/ROADMAP.md` (R4)
- **Problem:** Artifact hashes and mirror publisher authentication do not authenticate the mutable `index.json` to a client. The trust-release path signs trust inputs; repository metadata has no equivalent versioned, signed snapshot boundary.
- **Recommendation:** Add a versioned, signed release/snapshot boundary binding the exact index and referenced artifacts, with key provisioning, rotation/revocation, expiry, rollback/freeze handling, parser/size limits, and atomic publication. Compare an established update-metadata design before inventing a cryptographic protocol.
- **Progress:** Production planning requires `XSH_PM_REPO_KEY_FILE`; every signed fetch also requires durable `XSH_PM_REPO_STATE_DIR`. Signatures bind exact index bytes and referenced artifact digests. Accepted generation and clock floors are rechecked under an OS writer lock before packages are returned; planning holds its cache identity stable. Identical publication retries repair an interrupted signature write. All 30 snapshot cases and 80 surrounding publication/plan/CLI/graph cases pass. A real x86_64/KVM guest fetches over HTTP, rejects tampering, reboots with persistent state and rejects an older signed generation at the same URL. The laputa mirror previously answered 404 for `snapshot.json` and `snapshot.sig`, so signed publication and fetch worked only over `file://` and a test server; it now stores and serves both verbatim without redirecting them to an object cache, and a real loopback mirror passes `repo publish-snapshot` plus a verified fetch (four mirror API cases). Signed clients now read the index only through an immutable digest-named copy (`indexes/<sha256>.json`, published with the snapshot), so a newer `index.json` no longer breaks them until its snapshot is signed; the mirror enforces the digest name; the guest HTTP proof still passes. First-boot documents now provision the verification set (up to four `repo-key` lines to `/etc/laputa/repo-snapshot-keys`, mode 0444); tests rotate and revoke through re-application and check the installed file against the verifier. Rotation still requires an operator to re-apply; the signing key ceremony remains manual; there is no package-seeded repository key, TUF role delegation or threshold authorization. Parked: a package-seeded repository key and TUF-style role delegation or threshold signing need an owner key-ceremony decision, not code; qualifying the new `indexes/` fetch from the installed maintained guest needs a rebuilt `laputa-pm` in the maintained image (its current image predates the protocol); retry after the next maintained image build. See [PM snapshot authentication](docs/PM.md#snapshot-authentication).
- **Fix with:** architect
- **Effort:** L (weeks)

### LAP-47 · P2 · Complete ntpd-rs qualification and clock bootstrap policy

- **Area:** Time discipline
- **Where:** `ntpd-rs/`, imported from the `laputa-systems/ntpd-rs` fork at `910ecd0`, `2.0.0-alpha.20260715`
- **Problem:** aarch64 runtime qualification remains unproven. The chrony comparison covers startup steps and readiness, not slew, NTS interoperability or reboot policy. The packaged default pool is unauthenticated and no shipped profile enables it.
- **Recommendation:** Qualify the remaining cases in disposable guests before enabling an authenticated production configuration. Never alter the host clock. Cold boot requires trustworthy RTC or operator-set time; preserve TLS and snapshot expiry verification.
- **Progress:** The Graviola/rustcrypto musl package installs the daemon, ctl and exporter. Its wrapper drops to UID/GID 123 with only `CAP_SYS_TIME`; readiness means initialization, not synchronization. Real guest clocks converge from both positive and negative startup offsets. Forced restart, external-backstep restart/reselection and QMP pause/resume reselection pass. The loopback oracle pauses with the guest, and the external-backstep case does not prove convergence. An x86_64/KVM guest selected the authenticated external `time.cloudflare.com` NTS source before and after supervised restart; this does not independently measure clock accuracy. A controlled NTS guest verifies CA/name and `ntske/1`, records three authentication failures on tampered NTS replies before enabling valid replies, converges against the raw-clock oracle and restarts under supervision; its standalone runner passes end to end. Test-only chrony 4.9 confirms readiness while unsynchronized and startup stepping for both 20-second offset directions; its ahead runner also passes end to end. The package now persists steady frequency calibration without phase slew in a private UID/GID 123 directory. Twelve calibration tests pass on the host and in a root container. A controlled 100 ppm source proves learning and actual kernel frequency restoration after supervised restart and a fresh-kernel boot on the same state disk, before source selection and while unsynchronized. The exact final package also passes the NTS control with calibration enabled. The retained frequency shell runner also passes end to end on x86_64/KVM with the current ntpd-rs artifact closure, including both boots. This does not prove physical power-loss durability or hardware oscillator stability. Repository and trust-release v2 metadata now carry signed `issued-at`, and durable floors retain the greatest authenticated publication time rather than local wall observations. Legacy metadata/state require trusted reprovisioning that preserves generation floors. Existing installations must provision the reserved identity before enabling the service. See [time discipline](docs/ROADMAP.md#time-discipline-and-bootstrap), [guest checks](docs/TESTING.md#run-the-disposable-ntp-guest), [snapshot policy](docs/PM.md) and [trust policy](docs/CERTIFICATE-TRUST.md).
- **Fix with:** reference-parity
- **Effort:** M (days)
