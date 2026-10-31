# Performance measurements

These numbers describe the implementation after the XIN-1 session-reuse change.
They are measurements, not promises. The host was constrained during the run, so
the time gate was deferred. The change is accepted on the deterministic
connection count; the time change is indicative. The original O1 measurement is
recorded in [qualification](qualification.md).

## Environment

| Item | Value |
|---|---|
| Date | 2026-10-31 |
| Controller | macOS arm64 |
| XSH product | `target/aarch64-apple-darwin/release/xsh` |
| Guest | Alpine 3.23.4, OpenSSH 10.x, BusyBox 1.37 |
| xinfra guest | `xinfra-b` |
| pyinfra guest | `xinfra-a` |
| pyinfra | 3.10.0, Python 3.13, isolated `HOME` |

`perf-gate-ready -s` reported a constrained host. The run printed
`perf gate deferred: host busy`; `perf-gate-ready -1` was called after the
measurement.

## Method

Both guests started from the same reset: no `tree` package, no
`xinfra-q1-group`, no `xinfra-q1-user`, no performance base, and `crond`
stopped and disabled. The deployment creates one directory, one file, the
`tree` package, a group, a user with a home, one unconditional command, and
the `crond` service.

- Wall time is `time.monotonic()` around the controller process, including
  process launch and captured output.
- Peak RSS is `/usr/bin/time -l` maximum resident set size.
- SSH connections are the delta of `sshd` `Accepted publickey` lines in the
  guest `/var/log/messages`, excluding the `doas` and `sudo` command log lines
  that repeat the search text. A persistent controller session used for reset
  and log reads was open before and after each run, so it cancels out.
- Startup is the median of five `--version` runs.
- Handshake is the median of five connect, authenticate, and close runs.
- Round trip is the median of five `true` commands on one session.
- Local plan is the median of five module-load, validation, and
  empty-fact planning runs on the controller.

## Results

| Metric | xinfra | pyinfra 3.10.0 |
|---|---:|---:|
| Startup, median wall | 340 ms | 221 ms |
| Startup, peak RSS | 86 MiB | 55 MiB |
| First apply, wall | 791 ms | 758 ms |
| First apply, peak RSS | 91 MiB | 58 MiB |
| First apply, SSH connections | 2 | 1 |
| Second apply, wall | 489 ms | 368 ms |
| Second apply, peak RSS | 88 MiB | 58 MiB |
| Second apply, SSH connections | 2 | 1 |

Supporting measurements:

| Measurement | Value |
|---|---:|
| SSH handshake and authentication | 14 ms |
| Remote `true` round trip | 1 ms |
| Local module load, validation, and plan | 3 ms |

The pre-change tree measured 23 connections and 1004 ms first apply, 750 ms
no-op on the same host. The connection count is deterministic; the time
difference is indicative because the host was constrained.

## Interpretation

The connection gap is gone. A seven-resource deployment now opens two
connections: one for the initial fact pass and one for the locked phase that
acquires the lock, re-reads facts, applies every action, notifies services, and
releases the lock. pyinfra opens one. Each action runs on the host's existing
session, so handshake cost no longer scales with resource count.

`--jobs` now bounds parallel hosts within each resource stage. The
seven-resource single-host workload does not exercise it; the `multi-host`
integration case covers host concurrency.

xinfra still starts and runs more slowly than pyinfra on this run. The remaining
controller cost is startup and XSH evaluation, not SSH handshakes. The native
client is not claimed to be faster than pyinfra.

## Binary size

The stripped `dist` `xsh` binary is 23,704,272 bytes. W6 recorded the same
23,704,272 bytes, so the change is 0 bytes (0.0%). The 5% size gate passes.

## Limitations

- One run on a constrained host. Treat these values as indicative.
- The time gate was deferred, not passed.
- Only the macOS arm64 controller was measured.
- RSS is the controller process, not a sum over remote commands.
- The connection counter changed after O1. The earlier 24/2 counts are not
  comparable because the counter matched its own privilege-escalation log line.
