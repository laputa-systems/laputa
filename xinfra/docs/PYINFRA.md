# Comparison with pyinfra

Reference: pyinfra 3.5 in a throwaway container (`python:3.12-slim`, pinned
`pip install pyinfra==3.5`), run against its own disposable Alpine 3.22
container built from the same fixture image (with `openssh-sftp-server` added,
which `files.put` needs). The reference never ships.

## Differential result (2026-11-08)

`xsh fixtures/pyinfra.xsh diff [--scenario files|packages|services|commands|failures|all]`
applies each stage with pyinfra to a fresh Alpine container and with xsh-infra
to a running fixture host, then compares the resulting state (probed with
`stat`, `readlink`, `getent`, `ls`, `apk info -e`, `rc-service status`), whether
the run changed anything, and whether it succeeded. Output text and command
text are not compared. All five scenarios agree.

| Scenario | Stages | Agreement |
|---|---|---|
| files | directory `750 root:wheel`, file `640 root:wheel`, symlink, group `pig` gid 4401, user `piu` uid 4402 (primary group `pig`, `/bin/ash`, `/home/piu`): first, second | Same state; first changes, second is a no-op on both. |
| packages | install `jq` and `tree`; again; drift (`apk del jq` behind the tool); remove `tree` | Same installed set after every stage; install and repair change, again is a no-op on both. |
| services | OpenRC script plus enabled and running; again; drift (service stopped behind the tool); disabled and stopped | Same `rc-service status`, runlevel membership, script mode; again is a no-op on both. |
| commands | a `creates`-guarded command and an always-run command; run, again | Same files and log line counts (the guarded command ran once, the other twice). |
| failures | a failing command between two commands (broken, then fixed, then again); an unreachable host; a rejected key | Both exit nonzero, keep the earlier steps' effect, never run the later step, and converge after the fix; both fail the unreachable and unauthenticated hosts. |

The only state difference is in the files scenario:

| Difference | pyinfra | xsh-infra |
|---|---|---|
| Members of the user's primary group | `pig:x:4401:` | `pig:x:4401:piu` |

BusyBox `adduser -G` lists the user in the group's member field; `useradd -g`
does not. Both are valid; xsh-infra's check treats a primary group as satisfying
a membership either way.

Behavioral differences found while writing the commands and failures stages:

- pyinfra has no `creates`-style condition on `server.shell`; the equivalent is
  a guarded shell string, which pyinfra reports as changed on every run.
  xsh-infra reports the guarded command `skipped` on the second apply.
- After a failing operation pyinfra stops with "No hosts remaining" and exit
  status 1 and prints no results table; xsh-infra reports the failed resource,
  the blocked ones and every healthy host, and exits 3.
- pyinfra reports a rerun of an always-run shell as changed, as does xsh-infra.

## Deviations from pyinfra

| Topic | pyinfra | xsh-infra |
|---|---|---|
| Declaration | Python executed per host, operations discovered by running the file, hidden host context | Explicit typed values from a contract-checked `proc` with `[fs, error]`; no hidden context |
| Operation order | Source order, each operation a barrier across hosts | Declaration order adjusted for `needs`, merged across hosts; each operation a barrier |
| Plan | "Detected changes" from a dry pass; hidden side effects may alter later operations | Per-resource verdicts from fresh facts, with `(conditional)` where a dependency is planned to change and `uncertain` where a fact is unreadable |
| Failure | Failed host removed from later operations (by default) | Same default; `continue` and `abort` policies; failures are report data |
| Transport | paramiko (SFTP for file puts) | Native XSH client only; pinned SHA256 host keys; no `known_hosts` |
| Facts | Gathered by many shell commands, cached per host | One constant script per resource, never cached |
| Files | SFTP upload then move | Stdin streaming into a private staging file, digest check, optional validation, `mv -f` |
| Locks | None | Per-host `mkdir` lock with ownership token |
| Secrets | Python values in plans | Redacted everywhere; stdin-only delivery |
| Services | systemd, init.d, upstart, ... | OpenRC only; others refused |

## Controller cost (informational)

Measured on the 32-core development host, 2026-11-03, with `perf-gate-ready`
exiting 0 before and after (another lane's single-core job was running; no
other load). Medians of 21 runs for xsh-infra and 7 for pyinfra; peak resident
size is the maximum.

| Measurement | Wall | CPU | Peak RSS |
|---|---|---|---|
| `xinfra --help` (parse and check the program) | 260 ms | 250 ms | 59 MiB |
| `xinfra check`, no drift, 2 hosts, 9 resources each | 370 ms | 300 ms | 65 MiB |
| `xinfra apply`, no changes, same | 410 ms | 330 ms | 65 MiB |
| pyinfra no-op, 1 host, 5 operations (excludes `docker run`) | 761 ms | 229 ms | 54 MiB |

The workloads differ, so this is not a ranking. xsh-infra's fixed cost is the
check of its library at start; a first apply of the Alpine web example on two
hosts (package install, service start) took 1.1 s wall. Connections: one
authenticated session per host for the whole run, none for hosts that fail to
connect. No performance gate is defined for this repository.
