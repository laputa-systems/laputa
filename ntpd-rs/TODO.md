Prefix: NTPD
Next: 3

### NTPD-1 · P1 · prerelease daemon panics on NTS and rejects its sample config

- **Area:** Operability
- **Where:** `ntpd/src/daemon/mod.rs:197`, `ntpd/src/daemon/config/mod.rs:78`, `ntpd/src/daemon/config/server.rs:13`, `ntpd/src/ctl.rs:152`, `ntpd/src/force_sync/mod.rs:176`, `statime-algo/src/lib.rs:167`, `docs/examples/conf/ntp.toml.default:41`, `ntp.toml:22`
- **Problem:** The fork publishes Graviola prerelease binaries (`.github/workflows/prerelease.yml`) of a daemon whose run loop does not implement NTS. `daemon::run` spawns standard and pool sources, then `todo!()` on `mode = "nts"`, `nts-pool`, `sock`, `pps`, and `csptp`. `NtsSpawner` (`ntpd/src/daemon/spawn/nts.rs:46`) is never called. A config with only an NTS source parses and then panics. `Config` has no `[synchronization]` field, and the generated partial denies unknown fields (`statime-config-derive/src/lib.rs:143`), so `ntp.toml` and `docs/examples/conf/ntp.toml.default` do not load. `[[server]]` is an empty struct and is never bound. The observer spawn is commented out, so `ntp-ctl status` has no socket. `ntp-ctl validate` returns success without reading the path. `ntp-ctl force-sync` prints `Disabled for now`. A config that does parse is steered with `ClockConfig::default()`, whose jump abort thresholds are `None`, so `ClockInfo::check_jump` does not abort a step. The library NTS tests do not start `ntp-daemon`.
- **Recommendation:** Stop treating the prerelease zips as a clock service until `daemon::run` calls `NtsSpawner` for `mode = "nts"` and `Config` loads `docs/examples/conf/ntp.toml.default`, including its step limits. Keep `ntp-ctl validate` failing on a file the daemon would reject. Do not grow a second config schema in the fork. See the RFC.
- **Fix with:** none
- **Effort:** M
- **Design:** `docs/rfc/NTPD-1-daemon-not-operational.md`

