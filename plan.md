# mdevd-rs: Rust replacement for mdevd + mdevd-coldplug

## Status

- Goal: small robust Rust mdevd/mdevd-coldplug replacing the C implementation and skalibs, Laputa-compatible, libudev-zero-compatible on `-O 4`.
- Preflight: 2026-10-28, verdict `ready`. Base `eac18f5` (== `origin/main` HEAD).
- Accepted: R0 (be467c3), R1 (9470cd3), P1 (cb2c927), P2 (4370bb1),
  P3 (40ac52e), P4 (6267d45), P5 (09a3ea5), P6 (f082eb8). Red: none.
  Parked: daemon-driven kernel device-node creation (see Needs environment).
- Oracle bonus: C oracle + behavioral dump harness build reproducibly via
  `tools/build-oracle.sh`. Docker now supplies real-device adapter proof and
  kernel-event daemon publication proof on isolated resources.
- Live-multicast bonus: `unshare -U -n -r` runs the full P4 exchange here
  (consumer proof + Rust self-exchange).
- P6: 34 C-oracle transcript goldens (15 handling, 19 Laputa devices),
  selected applied-operation traces, config acceptance, acknowledged unicast
  drops with byte-exact empty `-o`, FIFO-acknowledged reload matrix,
  coldplug scan/CLI. Full locked suite and all-target clippy pass.
  A chmod-transcript mutation failed the comparison as required.
- Boundary: daemon intake rejects all userspace senders, including on `-I 2`;
  handling/order proof remains at dump-run and adapter level. Unicast warnings
  acknowledge every injected daemon record before comparing `-o` bytes.
- H1 device slice: Docker proves real character/block nodes, modes, ownership,
  aliases, repeated add/remove, identity refusal, inode/root replacement safety,
  execute-only ancestors, and zero FD growth over 10k repetitions.
  Kernel dummy-interface add/remove (including queue events) matches every
  C/Rust daemon `-o` byte and `-O 4` datagram after `-D` readiness, including
  traffic queued while a FIFO handshake holds config reload open.
  Ancestor-symlink mkdir/unlink and leaf-symlink chmod regressions were
  reproduced and fixed. Mutations now walk held non-symlink directory fds;
  metadata stays on the verified device inode. chmod requires procfs.
- Verified: `tools/check-privileged.sh`, adversarial tests, affected engine/bins/
  parity suites, and all-target clippy pass. Test boundaries: [local verification](docs/testing.md).
- Next: finish `H1` restart-during-coldplug, then
  `H2` and `O1`.
- H2 register must retain: hooks/firmware exclusions, HUP-retain, 60s bounded
  coldplug sync (`MDEVD_COLDPLUG_SYNC_TIMEOUT_SECS`), oversize-config error,
  absolute/`..` refusal and EEXIST identity adoption in RealOps,
  symlink-ancestor refusal and inode-pinned metadata (procfs required),
  uevent-NUL robustness, coldplug NULL-crash fixes.
- Resume: run `tools/check-pins.sh && cargo test --locked -q -- pins` on a clean tree.

## Charter

- Decide inside this doc and keep going. Record a decision only when a later slice depends on it.
- Authority grant: work in `mdevd-rs` only; read `libudev-zero` and Laputa read-only. No push; commits land on local branches/`main` for human review and push.
- Hard stops (park the item): irreversible or outside-repo action, a forbidden effect, or a loop with nothing checkable. Pushing always parks.
- Fix egregious breakage met on the way in its own commit: event-storm RSS growth >5% over 10k synthetic events, FD delta != 0, idle wakeups or coldplug time >2x the C reference. Otherwise record and leave it.
- Parity before optimization. Perf numbers are logged until `O1`; only the thresholds above gate earlier.
- One writer by default. Parallel lanes only for `P1||P2` and `H2||O1`, in worktrees at `.work/wt/<lane>`, never `/tmp`, per the orchestrate worktree lifecycle. Scratch goes under `.work/tmp`.
- Every commit is a Conventional Commit with the workstream as scope and the item ID in the body. Code comments never cite this doc.
- A failing item gets 3 attempts (root-cause: repro first, one hypothesis at a time, bisect after two refuted), then parks on `park/<ID>-<slug>` with cause and retry condition. Red never lands on `main`.
- After each accepted slice, run the parent steering checkpoint: name accepted slices, next slice, and confirm the tree is green.

## Decisions

Owner (2026-10-28):
- Hooks: v1 is declarative-only. Any line carrying a command (`@`/`$`/`*`/`+`/`-`/`&`) is rejected at parse with file, line, and "hooks unsupported". Laputa's `mdev.conf` needs none.
- Firmware: v1 excludes firmware loading. `FIRMWARE=` events are logged and skipped; `-F` is rejected with a non-zero exit naming the exclusion. No reads of `/lib/firmware`, no writes to `/sys/.../loading|data`.
- Upstream policy: this fork is not upstream; delete `CONTRIBUTING`'s LLM ban here (`H2`) and commit AI-authored work to this fork for human review and push.
- Test boundary: synthetic roots only. Owner authorized Docker proof on private
  tmpfs and private networks (2026-10-28). Host sysfs and device mutations remain forbidden.

Prescribed (from code, docs, or principles; reversed only by a new owner decision):
- Pins: `mdevd-rs` `eac18f5`, `libudev-zero` `8f1d3d06`, upstream mdevd `0.1.8.3` (`package/info`), Laputa-vendored `0.1.8.2` + skalibs `2.15.1.0` (`PKGBUILD.xsh`).
- Grammar: port the real two-pass tables (`src/mdevd/PARSING.txt`, `src/mdevd/mdevd.c:210-430`), not a simplified grammar. Regex via libc `regcomp`/`REG_EXTENDED` in an RAII wrapper; force `C` locale at startup; test musl behavior in `P1`.
- Netlink: intake default group `1`; kernel intake drops `nl_pid != 0` (`src/mdevd/mdevd_uevent_read.c:54-63`). Rebroadcast connects to `-O` minus `(intake|1)` with a startup warning naming dropped bits (`src/mdevd/mdevd.c:953-962`). `-O 4` matches libudev-zero's `UDEV_MONITOR_NLGRP 0x4` (`udev_monitor.c`: `udev` binds `0x4`, `kernel` binds `0x1`).
- Framing/bounds kept: NUL-separated records plus trailing NUL, 8192 B / 63 vars (`src/mdevd/mdevd-internal.h:6-7`), `MSG_TRUNC` fatal, `ENOBUFS` counted warning, plus a lost-event counter so drops never read as synced.
- Reload: parse and validate the whole new config before activating; invalid reload keeps serving the last valid config and errors loudly. Missing file keeps upstream behavior (warn + catchall default, `src/mdevd/mdevd.c:1009-1025`); any syntax error exits `2`. Tested in `P5`.
- Publish ordering: `-o`/`-O` emit only after device processing completes per the success/failure contract. `-o` write failure closes the fd and stops writing. Loop guard and coldplug sync mask bit 0 (`nlgroup &= ~1`, `src/mdevd/mdevd-coldplug.c:119`); sync wait ends on the last triggered `add` or a bounded timeout (executor picks 30-120 s and logs it), never on scan end alone.
- Deps: production `std`, `libc`, `rustix` plus transitives only. No Tokio, nix, clap, serde, parser generators, plugins, D-Bus, systemd, or `libudev` inside the daemon. `R1` gates this with `tools/check-deps.sh`.
- Toolchain: respect `rust-toolchain.toml` (pinned `nightly-2026-09-15` + `rust-src`, `clippy`; both musl targets installed). Never change the channel without an owner decision; all loop commands run under it, and `clippy` stays clean from `R1` on.
- Flags: support `-n -N -v -D -I -o -O -b -f -s -d -C` (`src/mdevd/mdevd.c:918`); `-F` rejected (firmware excluded). `-N` exits after parse with no mutation; `-n` mutates nothing. Readiness `-D` fires only when listening; `-C` spawns coldplug after listening; `SIGTERM` bounded cleanup, `SIGHUP` atomic reload; daemon never removes kernel nodes on exit.

Delegated (executor picks the smallest reversible option inside the bound and logs it):
- Module/file layout inside the owned dirs below; error-message wording; synthetic sysfs/dev tree shapes; C-consumer checkout (shallow, read-only, `.work/ref`, at or after `8f1d3d06`); perf fixture sizes within `O1` bounds.

## Baseline

- Tree: pure C skarnet package at `eac18f5`; no Rust workspace yet. `plan.md` untracked; everything else clean.
- Known red: C oracle not buildable here (no skalibs sysdeps, no `libskarnet`); privileged netlink/`/dev`/coldplug proof needs a VM (see Needs environment).
- Loop (2026-10-28, host busy: load ~16-26 on 32 cores): `git status` ~2 ms, `cargo new` ~0.11 s, hello-bin `cargo build` ~0.22 s (pre-pin toolchain; re-time under the pin in `R1`). Pinned toolchain `nightly-2026-09-15` active with both musl targets installed. Full-suite time set by `R1`.

## Sequence

- `R0` pins+oracle. Owns `tools/check-pins.sh`, `tests/pins.rs`, `tests/fixtures/laputa-*`. Needs: none. Proof: `tools/check-pins.sh && cargo test --locked -q -- pins`.
- `R1` workspace+loop. Owns `Cargo.toml`, `Cargo.lock`, `src/lib.rs`, `tools/check-deps.sh`; respects `rust-toolchain.toml`, does not modify it. Needs: `R0`. Proof: `cargo build --locked -q && cargo test --locked -q && cargo clippy --locked -q && tools/check-deps.sh`.
- `P1` config parser. Owns `src/config/`. Needs: `R1`. Proof: `cargo test --locked -q -- config` (Laputa fixture golden + hook-rejection + locale/musl cases).
- `P2` uevent intake. Owns `src/uevent/`. Needs: `R1`. Proof: `cargo test --locked -q -- uevent` (framing, dups, truncation, spoofed `nl_pid`, overrun accounting). May run parallel with `P1`.
- `P3` match+apply. Owns `src/engine/`. Needs: `P1`, `P2`. Proof: `cargo test --locked -q -- engine` (order/stop-continue, selectors, uid/gid/mode, rename/symlink/suppression, idempotence, traversal/swap/mismatch/stale-remove cases on synthetic roots).
- `P4` publish. Owns `src/publish/`, `tools/check-udev-consumer.sh`. Needs: `P2`, `P3`. Proof: `cargo test --locked -q -- publish && tools/check-udev-consumer.sh` (real C consumer on libudev-zero fork sees add/change/remove only after ready; Rust-only receiver does not count).
- `P5` binaries+lifecycle. Owns `src/bin/`. Needs: `P1`-`P4`. Proof: `cargo test --locked -q -- bins` (flag matrix incl `-N`/`-n` no-mutation, Laputa `-O 4 -f /etc/mdev.conf -C` fixture, readiness, `SIGHUP`/`SIGTERM`, coldplug sync/timeout/unavailable-daemon).
- `P6` differential harness. Owns `tests/parity/`. Needs: `P5`. Proof: `cargo test --locked -q -- parity` (config acceptance, planned vs actual ops, modes/aliases, CLI errors/signals, event order, coldplug/readiness; C side via oracle where runnable, else committed goldens + Laputa `proof.xsh` expectations).
- `H1` adversarial. Owns `tests/adversarial/`. Needs: `P6`. Proof: `cargo test --locked -q -- adversarial` (spoof/truncate/flood/backpressure, reload-during-traffic, remove/add races, fs replacement, restart-during-coldplug).
- `H2` docs+register. Owns `docs/`, `examples/xinit-mdevd.xsh`; deletes `CONTRIBUTING`. Needs: `P6`. Proof: `mdtool check --untracked plan.md docs` plus the divergence register names every intentional deviation. May run parallel with `O1`.
- `O1` perf. Owns `benches/`, `tools/measure-perf.sh`, `docs/perf.md`. Needs: `P6`. Proof: `tools/measure-perf.sh` (5+ alternating runs/side, median + spread, idle wakeups and coldplug vs C; gates only the Charter thresholds).
- `C1` close. Owns `.github/workflows/`, deletion diff, release profile. Needs: `H1`, `H2`, `O1`. Proof: `cargo test --locked -q && cargo clippy --locked -q && cargo build --locked --release --target x86_64-unknown-linux-musl && cargo build --locked --release --target aarch64-unknown-linux-musl && tools/check-ci-pins.sh` (locked deps, repro musl both targets, full-SHA CI pins, attribution, native-dep verification, dead-code removal, ultrareview P1/P2 clear, final report of unverified kernel behavior).

## Acceptance

- Parser: Laputa `mdev.conf` accepted with byte-identical planned ops vs reference semantics; hook lines fail loud with line numbers; `cargo test --locked -q -- config`.
- Intake: malformed/truncated/spoofed inputs rejected or counted, never trusted; overruns reported with lost-event evidence; `cargo test --locked -q -- uevent`.
- Apply: synthetic-root suite green incl traversal, ancestor replacement, symlink swaps, dev-number mismatches, stale removes, permission errors; repeats idempotent; `cargo test --locked -q -- engine`.
- Publish: C consumer on the pinned fork observes handled-event ordering and fields; no feedback loop on `(intake|1)`; backpressure bounded; `tools/check-udev-consumer.sh`.
- Binaries: `-N`/`-n` perform zero privileged mutations (assert via intercepted adapters); `-D`/`-C`/signals/coldplug-sync behave per contract; `cargo test --locked -q -- bins`.
- Parity gate: `cargo test --locked -q -- parity` green; every reference behavior in Reference has a failing-if-wrong test; intentional deviations all registered.
- Hardening/docs/perf/close per `H1`/`H2`/`O1`/`C1` proofs above. Full suite runs at `P6` and `C1`; slices run only their proof plus the narrowest affected suite on the integrated tree.

## Needs environment

- Docker now proves real node mutations through RealOps and daemon publication
  of genuine kernel add/remove events from private dummy network interfaces.
  `tools/check-privileged.sh` is the required command. Container isolation and
  capability limits are documented in [local verification](docs/testing.md).
- End-to-end daemon device creation from kernel events carrying major/minor
  numbers remains unverified. Private interface events do not carry them.
  Real hardware coldplug remains outside the synthetic-root boundary.
- Quiet-host perf confirmation for `O1` numbers (preflight host was loaded).

## Execution boundary and non-goals

- Authorized: read-only inspection of `libudev-zero` and Laputa; writes in `mdevd-rs` only; synthetic sysfs/dev roots under `.work/tmp`; `cargo build/test/run`, C-consumer compile in `.work/ref`; local branches and commits, no push.
- Forbidden: writing host `/sys/*/uevent`, `/dev`, firmware paths, or host uevent sockets; modifying Laputa or `libudev-zero`; integrating binaries into Laputa; depending on `libudev` in the daemon; adding D-Bus/systemd/logind/polkit; pushing.
- Non-goals (with reason): udev clone/device DB/policy engine/service manager (out of scope); new regex engine (libc POSIX is the reference); general hook language ( Laufsitzer hooks rejected in v1); physical-hardware/firmware campaign (virtual/fixture scope qualifies); optimization before `O1` (parity first).
- Contract changes for the owner: hooks rejected, firmware excluded with `-F` rejected, `CONTRIBUTING` deleted, missing-file warn+catchall retained, invalid reload retains last valid. All are tested above.

## Reference

- Oracle: `src/mdevd/mdevd.c` (loop `1044-1055`, config `1009-1027`, `-C` `1029-1036`, readiness `1037-1042`), `mdevd-coldplug.c` (scan, sync wait `145-157`), `mdevd_uevent_read.c`, `mdevd_netlink_init.c`, `PARSING.txt`, `doc/mdevd.html`, `doc/mdevd-coldplug.html`.
- Compat: libudev-zero `udev_monitor.c` at `8f1d3d06` (group `0x4`, framing/credential expectations); Laputa `packages/baselayout/files/rootfs/etc/mdev.conf`, `packages/mdevd/service.xsh` (`-O 4 -f /etc/mdev.conf -C`), `packages/mdevd/proof.xsh`, qemu-dwl-foot boot hook.
- Longer design material goes in `docs/`, linked from the divergence register; this doc stays the executable core.
