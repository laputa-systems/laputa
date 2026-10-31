Prefix: NTPD
Next: 5

### NTPD-2 · P2 · server, keyset, and NTS key-exchange server sections are not wired

- **Area:** Operability
- **Where:** `ntpd/src/daemon/config/server.rs`, `ntpd/src/daemon/server.rs`, `ntpd/src/daemon/keyexchange.rs`, `ntp.server.toml`
- **Problem:** `[[server]]` is an empty struct and `[keyset]` and `[[nts-ke-server]]` are not in `Config`, so the daemon cannot serve NTP or NTS key exchange and rejects `ntp.server.toml`. The server, key-exchange, and keyset code compiles but has no caller in the run loop.
- **Recommendation:** Add the sections to `Config` and start the server and key-exchange tasks from the run loop, publishing server statistics to the observer.
- **Fix with:** reference-parity
- **Effort:** M

### NTPD-3 · P3 · nts-pool, sock, pps, and csptp sources have no spawner

- **Area:** Operability
- **Where:** `ntpd/src/daemon/mod.rs`, `ntpd/src/daemon/spawn/{nts_pool,sock,pps,csptp}.rs`
- **Problem:** These spawners implement the spawner trait from before the controller rewrite and are outside the module tree, so `Config::from_args` rejects the modes with `ConfigLoadError::UnsupportedSource`.
- **Recommendation:** Port each spawner to the current trait as its source mode is needed.
- **Fix with:** reference-parity
- **Effort:** M
