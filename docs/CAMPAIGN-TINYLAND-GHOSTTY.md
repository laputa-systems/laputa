# Campaign: Tinyland + Ghostty graphical stack

Campaign record for the migration of Laputa's canonical graphical stack
from `dwl + foot` to Rust Tinyland (KBVM keyboard engine) + Ghostty Custom
terminal. The owner's mission text is the goal spec: implement, do not
merely roadmap; minimal closure; reuse working implementations and proof
infrastructure; deterministic offline packaging. This doc turns that goal
into sequenced deliverables with runnable proofs. The status section
records what landed; the sequence remains the plan of record.

There are no prior `docs/CAMPAIGN-*.md` or `DECISIONS.md` in this repo; this
is the first campaign doc. It follows the owning topic docs' style: claims
cite measured artifacts and exact proof commands.

## Baseline (measured 2026-10-30, Linux x86_64)

| Item | Value | Source |
|---|---|---|
| `tinyland` binary | 2,117,480 bytes | store payload of `tinyland-0.1.0-1` (`fd64294d…`) |
| `tinyland` DT_NEEDED | `libseat.so.1`, `libxkbcommon.so.0`, `libgcc_s.so`, `libc.so` | `readelf -d` on the same payload |
| Tinyland Cargo graph | 80 locked crates, `xkbcommon 0.9.0`, no `kbvm` | `tinyland/Cargo.lock` |
| Tinyland toolchain | `nightly-2026-09-15` | `tinyland/rust-toolchain.toml` |
| `qemu-tinyland-foot` closure | 41 plan nodes | `target/laputa/qemu-tinyland-foot/build-plan.json` |
| `qemu-tinyland-vt-foot` closure | 41 plan nodes | `target/laputa/qemu-tinyland-vt-foot/build-plan.json` |
| `qemu-dwl-foot` closure | 48 plan nodes | `target/laputa/qemu-dwl-foot/build-plan.json` |
| Mesa 26.2.4 config | EGL/GBM/GLES on softpipe+virgl, `-Dopengl=false -Dllvm=disabled`, `-Dglx=disabled` | `packages/mesa/PKGBUILD.xsh:199-232` |
| Ghostty Custom release | `release-354a4e32dc4959ec10709adbdeac114594a05097` at commit `354a4e3`, published 2026-10-30, 7 assets; Linux tarballs "mostly-static musl (dynamic libEGL, libwayland-client, libxkbcommon only)" | release page, verified 2026-10-30 |
| Repo references to ghostty/kbvm | none | `grep -rli` over `packages/ profiles/ docs/ tinyland/src tinyland/Cargo.*` |
| Tinyland proof surface | `harness/{proof,run-proof,check-proof,wayland-pixels,drm-proof,drm-parity,seat-proof,negative-runtime,smoke}.sh`, `harness/test-qmp.py`, guest QMP input + screenshot checks | `tinyland/harness/`, `tinyland/AGENTS.md` |

Rule the baseline sets: every phase below re-measures its row and fails on
unexplained regression. KBVM 0.2.0 MSRV (1.95) vs the pinned nightly is
unverified — Phase 0 settles it by compiling, not by reading version
strings.

## Status (2026-10-31)

Measured on Linux x86_64/KVM with the fixed Ghostty build described under
"Blocking release".

| Phase | State | Evidence |
|---|---|---|
| 0 inventory | landed | baseline table; `tinyland/docs/opengl-probe.md` |
| 1 KBVM | landed | `tinyland` DT_NEEDED has no libxkbcommon; `tinyland/tests/kbvm_oracle.rs` |
| 2 Ghostty package | landed | `ghostty-custom` proof; four declared DT_NEEDED entries |
| 3 OpenGL probe | landed | guest virgl reports 4.3 core; softpipe ceiling is 3.3 |
| 4 profile | landed | `qemu-tinyland-ghostty`; `LAPUTA_TINYLAND_GHOSTTY_GL43` |
| 5 end-to-end | complete | `make profile-test` from `ghostty-custom-1.4.1-2` |
| 6 size/performance | complete | table below |
| 7 promotion | complete | canonical profile and rollback targets |

### Phase 5 proof

From the published `release-15e551072…` package,
`make profile-build` then `make profile-test` passes. The guest proof covers the
lifecycle matrix (compositor crash, broker loss, single keyboard unplug,
application exit, scanner shutdown with ownership reclamation),
unprivileged DRM and evdev denial, Ghostty on a 4.3 core context, and ends
with `LAPUTA_TINYLAND_GHOSTTY_PROOF_OK`. The host screenshot is 1280x800
with 0.61% magenta pixels from the terminal marker.

Input covers a Caps Lock round-trip, Shift+1, a bare Shift press/release
between keys, and Return; the reader receives `LAPUTA!`. Two proof defects
were found and fixed:

- The reader waited for `io.stdin_text()` EOF. The injected Ctrl+D races
  the line it follows on a canonical tty: the line is still queued, so the
  EOF character is discarded and the reader blocks forever. The proof
  injects a line, so the reader now uses `io.stdin_line()`.
- QEMU answers `screendump` with `no surface` once the guest scans out
  through a GL device, because the frames stay GL textures. Virgl profiles
  now carry a 2D `virtio-gpu-pci` first as card0 for scanout and
  `virtio-gpu-gl-pci` as the render device, so tinyland scans out through a
  host-readable surface while Ghostty renders on the virgl render node.

### Release

`release-15e55107259d2118c0061100ec0a9d2167f72ae4` publishes the fork fix:
create the seat at registry-bind time and replace the yield loop with a poll
on the display fd. The recipe pins x86_64 `9b56d0b8…` and aarch64
`110f7f08…` as `ghostty-custom-1.4.1-2`. The earlier release
`release-354a4e32…` binds `wl_seat` before its listener exists, so the
client never creates a keyboard (see `tinyland/docs/opengl-probe.md`).

### Phase 6 numbers

| Item | Value | Source |
|---|---|---|
| `tinyland` binary | 3,015,600 bytes (baseline 2,117,480) | `tinyland-0.1.0-1` payload |
| `tinyland` DT_NEEDED | `libseat.so.1`, `libc.so`, `libgcc_s.so` | `readelf -d` |
| `ghostty-custom` binary | 30,586,216 bytes; payload archive 18,516,608 bytes | `ghostty-custom-1.4.1-2` payload |
| `ghostty-custom` DT_NEEDED | `libEGL.so.1`, `libwayland-client.so.0`, `libxkbcommon.so.0`, `libc.so` | package proof |
| `qemu-tinyland-ghostty` closure | 38 plan nodes (foot 41, dwl-foot 48) | `target/laputa/qemu-tinyland-ghostty/build-plan.json` |
| Image size | disk 308M, rootfs 276M (foot 288M/256M) | `du` on `current/` |
| Cold start to first frame | session ready with a 4.3 context at 13.93 s guest uptime (proof start 10.39 s); prior runs measured 10.51-13.82 s | `LAPUTA_TINYLAND_T session-ready` |
| Idle RSS after input | tinyland 7,176 KB; Ghostty 41,352 KB | `LAPUTA_TINYLAND_RSS` |
| Generation SHA-256 | `a772427bbd31516d32a7009821b05e09bb451b9ec8d217736512ed88918482b7` | `current/generation.json` |
| Renderer | virgl, OpenGL 4.3 core | `LAPUTA_TINYLAND_GHOSTTY_GL43` |

### Promotion

`make profile-*` now builds, tests, and boots `qemu-tinyland-ghostty`. The
dwl and foot profiles keep `make profile-dwl-*`, `make profile-tinyland-*`,
and `make profile-tinyland-vt-*` as rollbacks, and the docs name the new
canonical profile. The canonical test needs a host virgl render node; the
foot rollbacks remain the path for hosts without one.

## Reuse / change / new map

- Reuse: `tinyland/` poll loop, seat lifecycle, VT switching, DRM
  presentation proofs; `profiles/qemu-tinyland-foot.xsh` session model;
  `packages/terminfo` + XSH `tic`; `packages/mesa` deterministic generated
  workflow; `docs/TINYLAND.md`, `docs/QEMU.md` proof contracts.
- Change: `tinyland/src/input.rs` (+KBVM backend, `xkbcommon` crate out of
  runtime deps); `packages/mesa/PKGBUILD.xsh` only if the OpenGL 4.3 probe
  demands it; default-profile selection only in Phase 6.
- New: `packages/ghostty-custom/` recipe + proofs; `qemu-tinyland-ghostty`
  profile (+VT variant); Ghostty-path guest markers and pixel assertions;
  `tinyland/docs/` baseline report.

## Deliverables (each with proof command and threshold)

1. **Baseline report** in `tinyland/docs/`: the table above plus `cargo
   tree` deltas, guest proof inventory, and the KBVM toolchain verdict.
   Proof: report exists, every number reproducible by a cited command.
2. **KBVM keyboard backend**: Tinyland compiles with KBVM, `readelf`
   shows no `libxkbcommon`, `cargo tree` shows no C XKB binding.
   Proof: `cargo test --locked` green; differential tests vs libxkbcommon
   oracle green (oracle test-only); `make smoke wayland-pixels drm-proof
   drm-parity negative` green; foot client unchanged and QMP-typed input
   reaches its PTY with correct modifiers (existing `qemu-tinyland-foot`
   proof unmodified and passing).
3. **Ghostty Custom package**: arch-pinned tarballs with recorded SHA-256
   (no `SKIP`), `/usr/bin/ghostty-custom`, `xterm-ghostty` terminfo
   present and readable, `--version`/`+show-config` green in the proof
   root, DT_NEEDED exactly the declared set (no GTK/D-Bus/XWayland/
   systemd, no glibc), no `/bin/sh` in launch paths.
   Proof: `pm` package proof green on both arches (compile proof;
   aarch64 runtime explicitly not claimed).
4. **OpenGL feasibility proof**: standalone guest EGL init on the
   intended driver, desktop core ≥4.3 context, offscreen render with
   readback pixel match, packaged Ghostty renderer init. If softpipe
   cannot do 4.3, the decision (virgl vs llvmpipe with measured LLVM
   cost) is recorded with numbers before any Mesa flag changes.
   Proof: guest-executed, not build-only; no version-override env vars.
5. **Ghostty profile + end-to-end proof**: `qemu-tinyland-ghostty`
   boots; Ghostty maps `xdg_toplevel`, renders text, screenshot shows
   nonblank expected pixels with DRM-completion confirmation; QMP-injected
   string (incl. Shift/Caps/modifier-interrupt cases) reaches the PTY
   reader; lifecycle matrix green (Ghostty exit, compositor crash
   recovery, seatd fail-closed, keyboard removal without stuck modifiers,
   VT switch round-trip, no orphan processes/descriptors); unprivileged
   direct DRM/evdev opens still denied. Foot profiles untouched and
   still passing.
6. **Size/performance report**: before/after Tinyland binary, Cargo
   counts, both ELF `DT_NEEDED` sets, profile package count and image
   sizes, cold-start-to-first-frame, idle RSS, selected renderer. Large
   regressions are investigated decisions, not auto-failures.
7. **Promotion (only after 1–6)**: canonical default switched, docs and
   profile assertions updated, dwl/foot retained as rollback profiles.
   Proof: default `make profile-*` targets exercise the new stack while
   every old profile still passes.

## Sequence

Phase 0 (inventory + baseline report) first, by one lane — everything
quotes it. Then Phase 1 (KBVM) and Phase 2 (Ghostty package) may run in
parallel: disjoint trees (`tinyland/` vs `packages/ghostty-custom/`),
shared nothing except the Phase 0 report. Phase 3 (Mesa/OpenGL probe)
needs the Phase 2 binary; Phase 4 (profile) needs Phase 1 + the Phase 3
renderer verdict; Phase 5 (end-to-end) needs Phase 4; Phase 6
(size/performance) needs Phases 1-5; Phase 7 (promotion) needs Phase 6
plus the Phase 0 rollback profiles. No
lane invents XKB, Wayland, renderer, PM, or compositor machinery; blocked
integration lands the independently proven half and documents the exact
blocker with its reproducer.

## Execution authority

Normal Laputa development effects only: Docker builds, KVM guests on the
Linux x86_64 host, `make fetch`-style pinned-source downloads (KBVM
crate sources, Ghostty release tarballs + SHA256SUMS), commits directly
to the default branch per the mission. Forbidden: systemd/D-Bus/GTK/
wlroots/XWayland/display-manager/general-desktop additions; C or FFI in
Tinyland beyond the reviewed libseat boundary; faked screenshots or
markers; weakening any existing proof. aarch64 guest runs and any
macOS-host execution go on **Needs environment** (roadmap defers Linux
aarch64 qualification); aarch64 work is compile/package proof only.

## Verdict: ready

No owner questions remain: the mission already decides direct commits, no
PR ceremony, rollback retention, and the failure-handling rule (prove
halves independently, never claim completion without guest evidence).
Prescribed decisions the owner may overrule: (a) virgl preferred over
llvmpipe unless the Phase 3 probe proves otherwise with numbers; (b)
`xterm-ghostty` via source-matched fixture + XSH `tic`, never by
executing a cross-arch binary; (c) KBVM oracle tests stay libxkbcommon-
dependent and optional, production test commands C-free. Could not verify
from here: KBVM 0.2.0 source compatibility with the pinned nightly;
Ghostty tarball payload hashes (Phase 2 pins them); whether softpipe
does OpenGL 4.3 core (Phase 3 probe decides).

First slice: Phase 0 inventory + baseline report (one lane, doc +
read-only probes). Parallel after it: Phase 1 and Phase 2 lanes.

Executor launch prompt: `Implement docs/CAMPAIGN-TINYLAND-GHOSTTY.md Phase 0, then Phase 1 and Phase 2 in parallel lanes; stop before any Mesa flag change and report the Phase 3 probe plan.`
