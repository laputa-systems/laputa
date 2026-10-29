# mdevd-rs

Linux Rust replacement for the mdevd hotplug daemon and the
`mdevd-coldplug` helper. Deny by default; fail closed on every error
path; no shell, no firmware loading, no hooks.

## Commands

```sh
cargo test --locked
cargo clippy --locked --all-targets
sh tools/check-qemu.sh
sh tools/check-combined.sh
sh tools/check-udev-consumer.sh
sh tools/measure-perf.sh
```

Musl release builds link with `mold` via `RUSTFLAGS="-Clinker=mold -Clinker-flavor=ld"`.

## Invariants

- Config larger than 8191 bytes is rejected, never truncated.
- One effect adapter owns each mutation; no `unsafe` outside narrow FFI.
- Only `libc` in production (`tools/check-deps.sh` gates this).
- No `libudev` dependency; libudev-zero consumers read the `-O 4` rebroadcast.

## Map

- Config grammar and tables → `src/config/`
- Netlink intake → `src/uevent/`
- Match and apply → `src/engine/`, real adapter → `src/engine/ops.rs`
- Processed-event publication → `src/publish/`
- Daemon and coldplug binaries → `src/bin/mdevd.rs`, `src/bin/mdevd-coldplug.rs`
- Behavior contract and divergences → `docs/divergence.md`
- Verification, performance, release → `docs/testing.md`, `docs/perf.md`, `docs/artifacts.md`
- Guest harnesses and fixtures → `guest/`, `tools/check-*.sh`, `tests/fixtures/`
