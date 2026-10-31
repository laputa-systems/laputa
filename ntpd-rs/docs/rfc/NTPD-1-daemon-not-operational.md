# NTPD-1: what to ship while the daemon loop is unwired

Status: draft

## Summary

This fork's prerelease binaries are built from a tree where `ntp-daemon` panics on NTS sources and rejects the sample configuration. The Graviola TLS provider is real. The daemon entry point that would use it is not. Decide whether prereleases stay unpublished as a clock service until upstream reconnects that loop, or this fork patches the loop itself.

## Motivation

`daemon::run` in `ntpd/src/daemon/mod.rs` is the process the prerelease zip installs. An NTS source is the only path that exercises `rustls-graviola`. That arm is `todo!()`. `NtsSpawner` already builds a `KeyExchangeClient` with the provider from `ntp-proto/src/tls_utils.rs`.

`Config` no longer has a `[synchronization]` section. `docs/examples/conf/ntp.toml.default` and `ntp.toml` still contain one, and the config derive rejects unknown fields. A pool-only file that omits that section does start, and it uses `ClockConfig::default()`. That value sets no step abort threshold.

`ntp-ctl validate` returns success without opening the file. `ntp-ctl status` has nothing to connect to because the observer spawn is commented out.

Publishing those binaries, or documenting an OpenRC install, tells an operator the Graviola profile is a clock service. It is a TLS provider plus a daemon that will not serve that config.

## Design

Leave the protocol crates and the Graviola feature as they are.

Do not add a fork-only configuration schema. The sample file and `docs/man/ntp.toml.5.md` stay the contract. The code is what fails that contract.

Until `daemon::run` does all of the following, do not describe the prerelease zip as something to run as `ntpd`:

- `mode = "nts"` constructs `NtsSpawner` and does not panic.
- `docs/examples/conf/ntp.toml.default` loads, and its step limits are the limits `check_jump` enforces.
- `ntp-ctl validate -c` that file exits 0, and a file with an unknown key exits non-zero.

Server listen, the observer socket, and `force-sync` are the same disconnection. They can land with the sample-config fix or in a follow-up. They are not a reason to keep shipping the current binary as a service.

## Alternatives considered

Patch only the `todo!()` arm and keep publishing. That stops the NTS panic and still ignores the sample file's step limits. An operator who deletes `[synchronization]` to make the file parse gets a daemon that will step the clock with no ceiling.

Rewrite `docs/man/` down to the empty `Config` and `NtpServerConfig`. That records a temporary hole as the contract and will be wrong again when the fields return. The man page is the spec. The code is behind it.

Vendor a full daemon loop in the fork, parallel to upstream. Two clock daemons will diverge on every upstream rewrite commit.

## Open questions

- Wait for upstream to reconnect `daemon::run`, or patch `NtsSpawner` and the sample-config load on this fork now?
- Should a prerelease workflow dispatch fail while `todo!()` remains in `daemon::run`?

Recommendation: do not dispatch prereleases as a clock service, and do not fork a second schema. If this fork needs an NTS client before upstream finishes, call the existing `NtsSpawner`. Load the keys the sample file already uses, and enforce those step limits.

## Decision

Undecided.
