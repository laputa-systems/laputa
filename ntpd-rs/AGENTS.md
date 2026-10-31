# ntpd-rs (laputa-systems fork)

Fork of [pendulum-project/ntpd-rs](https://github.com/pendulum-project/ntpd-rs).
NTP and NTS code matches upstream except the Graviola TLS provider below.
This checkout's `ntp-daemon` does not implement the configuration in
`docs/man/ntp.toml.5.md` or `docs/examples/conf/ntp.toml.default`.
That gap is `TODO.md` NTPD-1.

## Graviola TLS provider

- Opt-in `graviola` feature on `ntpd` and `ntp-proto`.
  `ntp-proto/src/tls_utils.rs` passes `rustls_graviola::default_provider()`
  into the rustls builder and into the platform verifier. It does not install
  a process-global provider.
- `graviola` is mutually exclusive with `aws-lc` and with `openssl`.
  Building `ntpd` or `ntp-proto` with no TLS provider fails at compile time.
  The `aws-lc` feature of `ntpd` enables the same feature on `ntp-proto`.
- The profile without C-backed cryptography is
  `--no-default-features --features graviola,rustcrypto`.
  It has no `srv` feature, so it does not do NTS SRV lookup.
  Direct hostname lookup still works (`ntpd/src/daemon/dns.rs`).
- `Cargo.lock` resolves `rustls-graviola` 0.4.0 and `graviola` 0.4.1.
  That crate uses `getrandom` 0.3.4. The same graph also contains
  `getrandom` 0.2.17. `deny.toml` already allows Apache-2.0 and MIT.
- The first Graviola call panics if CPU features are missing.
  On x86_64 those are `aes`, `pclmulqdq`, `bmi1`, `adx`, `avx`, and `avx2`.
  On AArch64 they are `neon`, `aes`, `pmull`, and `sha2`.

## Daemon in this checkout

- `ntpd/src/daemon/mod.rs` starts standard and pool sources only.
  `mode = "nts"`, `nts-pool`, `sock`, `pps`, and `csptp` hit `todo!()`.
  `NtsSpawner` (`ntpd/src/daemon/spawn/nts.rs`) is not called.
- `Config` (`ntpd/src/daemon/config/mod.rs`) has `use-system-config`,
  `source`, `server`, and `observability`. A `[synchronization]` table is
  rejected. `NtpServerConfig` has no fields, and the run loop does not bind
  servers. The observer spawn is commented out, so `ntp-ctl status` has no
  socket. `ntp-ctl validate` returns success without reading the file
  (`ntpd/src/ctl.rs`). `ntp-ctl force-sync` prints `Disabled for now`.
- The run loop passes `ClockConfig::default()` and
  `SynchronizationConfig::default()`. The sample file's step limits are not
  applied. The default clock config sets no step abort threshold.
- `UnixClock::now` calls `adjtimex` and, on failure, `clock_gettime`.
  Later steering still needs `CAP_SYS_TIME`.

## Build and prereleases

- MSRV is Rust 1.95 (`Cargo.toml` `rust-version`). The release compiler
  channel lives only in `.rust-toolchain/stable/rust-toolchain.toml`.
  `rust-toolchain.toml` is a symlink to it, the macOS prerelease job reads
  it via `.rust-toolchain/set-rust-versions.sh`, and the Linux image parses
  it in the `Dockerfile`.
- CI rejects `aws-lc-rs`, `aws-lc-sys`, `ring`, `openssl`, and `openssl-sys`
  on the Graviola musl graph (`.github/workflows/checks.yaml`). Locally:
  `cargo tree --locked --prefix none -p ntpd --target x86_64-unknown-linux-musl --no-default-features --features graviola,rustcrypto --edges normal,build`.
- Prereleases are manual: `gh workflow run prerelease.yml --ref main`.
  The workflow accepts only the default branch, builds
  `aarch64-apple-darwin` and both musl targets with the Graviola profile,
  checks that the Linux binaries have no dynamic interpreter, and publishes
  zips plus `SHA256SUMS` on tag `release-<sha>`.
- Linux builds use the root `Dockerfile` (pinned Alpine, verified rustup
  1.29.2, musl LLVM). The workflow runs `cargo` with the image `cc` linker.
  `musl-cargo` is in the image. The workflow does not invoke it.
- Repomod catalog entry: `laputa-systems/ntpd-rs = ["tool", "rust", "fork"]`.

## Docs

- `docs/guide/` and `docs/man/` describe Pendulum ntpd-rs. They do not match
  this checkout's `Config`.
- `docs/guide/installation.md` has the Graviola cargo command.
