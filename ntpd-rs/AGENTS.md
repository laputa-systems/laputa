# ntpd-rs (Laputa)

Maintained here, in the Laputa monorepo, and nowhere else. It descends from
[pendulum-project/ntpd-rs](https://github.com/pendulum-project/ntpd-rs)
through the `laputa-systems/ntpd-rs` GitHub fork, now archived; this tree was
imported from fork commit `910ecd02` (`2.0.0-alpha.20260715`).
NTP and NTS code matches upstream except the Graviola TLS provider below and
the daemon repairs recorded in git history. Remaining daemon gaps are in
`TODO.md`.

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

- `ntpd/src/daemon/mod.rs` starts standard, pool, and NTS sources.
  `NtsSpawner` (`ntpd/src/daemon/spawn/nts.rs`) runs one key exchange per
  spawn with the provider-backed `KeyExchangeClient`; `certificate-authority`
  adds roots to the platform verifier, and the retry backoff in `System`
  covers a failed handshake, including one caused by a wrong clock.
  `nts-pool`, `sock`, `pps`, and `csptp` have no spawner, so
  `Config::from_args` rejects them with `ConfigLoadError::UnsupportedSource`
  and `run` returns the same error. The old-trait `nts_pool.rs`, `sock.rs`,
  `pps.rs`, and `csptp.rs` spawners stay out of the module tree until they
  are ported.
- `Config` (`ntpd/src/daemon/config/mod.rs`) has `use-system-config`,
  `source`, `server`, `observability`, and `synchronization`. The
  `[synchronization]` table is `ntp_proto::SynchronizationConfig`:
  `SynchronizationSettings::clock_config` turns its step limits into the
  `statime_algo::ClockConfig` jump abort thresholds, and
  `minimum-agreeing-sources`, `local-stratum`, and `reference-id` reach the
  controller and `NtpManager`. `Config::check` fails when fewer sources are
  configured than `minimum-agreeing-sources`. `NtpServerConfig` has no
  fields, and the run loop does not bind servers. The run loop binds
  `observation-path` before it reports readiness and exits if it cannot,
  then serves `ObservableState`: the system snapshot comes from the
  one-second timer loop in `System::run`, and each `SourceTask` publishes
  its source through `SourceObserver` and withdraws it when it ends.
  `ntp-ctl status` prints no per-source offset. `ntp-ctl validate`
  loads the file through `Config::from_args` and exits 1 on any load error
  or failed `Config::check` (`ntpd/src/ctl.rs`). `ntp-ctl force-sync` is
  removed; recovering from a clock beyond the startup limits means setting
  the clock by hand before starting the daemon.
- `UnixClock::now` calls `adjtimex` and, on failure, `clock_gettime`.
  Later steering still needs `CAP_SYS_TIME`.

## Readiness

- The run loop reports readiness after the configuration is loaded, the
  observation socket is bound, and the spawners are registered, never after
  synchronization. With `NOTIFY_FD` set it writes one byte to that
  descriptor (`ntpd/src/notify.rs`), reopened through `/proc/self/fd`
  because the crate forbids unsafe code; a failed write ends the daemon.
  `NOTIFY_SOCKET` (systemd) is still honored best-effort.
- Synchronization is separate: `ntp-ctl status` reports stratum 16 until a
  source is in use.

## Build and prereleases

The fork's `.github/` workflows, `Dockerfile`, and `Cross.toml` came across
with the import. They cannot run from this subdirectory; Laputa builds the
package from `packages/ntpd-rs`.

- MSRV is Rust 1.95 (`Cargo.toml` `rust-version`). The release compiler
  channel lives only in `.rust-toolchain/stable/rust-toolchain.toml`.
  `rust-toolchain.toml` is a symlink to it, the macOS prerelease job reads
  it via `.rust-toolchain/set-rust-versions.sh`, and the Linux image parses
  it in the `Dockerfile`.
- CI rejects `aws-lc-rs`, `aws-lc-sys`, `ring`, `openssl`, and `openssl-sys`
  on the Graviola musl graph (`.github/workflows/checks.yaml`). Locally:
  `cargo tree --locked --prefix none -p ntpd --target x86_64-unknown-linux-musl --no-default-features --features graviola,rustcrypto --edges normal,build`.
- Linux builds use the root `Dockerfile` (pinned Alpine, verified rustup
  1.29.2, musl LLVM). The workflow runs `cargo` with the image `cc` linker.
  `musl-cargo` is in the image. The workflow does not invoke it.

## Docs

- `docs/guide/` and `docs/man/` describe Pendulum ntpd-rs. They match this
  checkout's `Config` except for `[[server]]`, `[keyset]`,
  `[[nts-ke-server]]`, `[source-defaults]`, and `[synchronization.algorithm]`,
  which the daemon rejects as unknown fields.
- `docs/guide/installation.md` has the Graviola cargo command.
