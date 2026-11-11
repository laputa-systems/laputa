# Capability and platform matrix

"Qualified" means exercised by the test suite against the named environment.
Container and controller results are from 2026-11-10; the VM results are from
2026-11-11. Everything else is untested.

## Controller

| Platform | Status |
|---|---|
| Linux x86_64 (musl-linked XSH, verification profile of XSH `b69f21f14`) | Qualified: unit, local-engine, CLI, install, Alpine/SSH container and QEMU/KVM VM suites, and two-process cancellation on both fixtures. |
| macOS aarch64 | Not qualified here: no macOS host was available. XSH-55 reports its native `ssh` module passing on macOS; xsh-infra adds no platform-specific code, but its own suite has not run there. |
| Other | Untested. |

## Targets

| Target | Status |
|---|---|
| Alpine 3.22 container: OpenSSH 10.0p1 sshd (Ed25519 host key and client key), BusyBox 1.37, doas, OpenRC with `rc_sys=docker`, `shadow` for `usermod` | Qualified. |
| Real Alpine VM with a full init | Qualified: Alpine 3.22.8 cloud image (pinned URL and sha256) under QEMU/KVM, one guest per copy-on-write overlay. PID 1 is OpenRC `init`; `rc-status` reports the default runlevel with `sshd` started. The file/directory, package, service, user/group, command, failure, process and two-process cancellation suites pass. See [Testing](TESTING.md#disposable-alpine-vm). |
| Laputa | Not supported: its services belong to xinit and no adapter exists. Files, directories, links and commands only need the POSIX baseline and should work, but are untested on Laputa. |
| Other Linux | The POSIX baseline below is expected to work; packages, users, groups and services are Alpine-only and fail clearly (`uncertain`/`failed`, cause `unavailable`) when the tools are missing. |

## Remote baseline

POSIX `sh`, and `stat -c`, `sha256sum`, `od`, `tr`, `mktemp`, `mv`, `readlink`,
`chmod`, `chown`, `ln`, `rm`, `mkdir`, `rmdir`, `cat`, `awk`, `id`, `sed`, `wc`,
`head`. `doctor` reports what is missing. For packages: `apk` and a readable
`/lib/apk/db/installed`. Users and groups: BusyBox `adduser`, `addgroup`,
`deluser`, `delgroup`; changing an existing user's shell, home or primary group
needs `usermod`. Services: `rc-service` and `rc-update`. The remote login shell
must accept POSIX single quotes; `doctor` checks.

## Resources

| Resource | First apply | Second apply | Drift repaired | Plan/check mutate nothing | Unreadable or unavailable is not absence | Notes |
|---|---|---|---|---|---|---|
| directory | yes | no change | yes | yes | yes | absent removes only empty directories |
| file | yes | no change, mtime kept | yes | yes | yes | staged, validated, atomic `mv`, binary streams |
| symlink | yes | no change | yes (with `replace`) | yes | yes | replace is remove then `ln -s`, not atomic |
| package | yes | no change | yes | yes | yes | needs network to the repositories |
| package index | yes | runs again | n/a | not evaluated | n/a | apply only, always runs when declared |
| group | yes | no change | n/a | yes | yes | gid conflicts are refused |
| user | yes | no change | yes (shell, home, groups) | yes | yes | uid conflicts are refused, data kept |
| command | yes | skipped by its condition | n/a | guards run read-only | yes | `always` and `run_on` are not verifiable |
| service (OpenRC) | yes | no change | yes | yes | yes | reload/restart once per apply |

## Cancellation

`test-alpine-cancel` signals a running apply from a second process on `fx-3`.
The VM fixture starts `fx-3` alone (`up --count 1 --first 3`) so the two-VM
ceiling holds while the cancellation suite runs. Every boundary is held from
the target side: a blocking command resource before
or after the resource under test marks when the apply has reached that point,
and in-flight commands, streamed transfers and service reloads expose their own
remote markers. The controller reports the resource being reconciled `unknown`
and unstarted resources `blocked` on stderr, exits 3, releases the lock, never
replays the request, and a re-run converges. Atomic single-request operations
(`mkdir`, `ln -s`, account adds, `apk add`, `apk update`) have no separately
holdable in-flight interior; the gates cover their before and after boundaries.

## Not exercised

macOS; Linux aarch64; a VM image other than the pinned Alpine 3.22.8 x86_64
BIOS cloud image; an OpenRC service start interrupted inside `start_pre`, which
leaves OpenRC's `starting` state and needs an operator stop before a re-run (the
in-flight service case uses a reload instead).
