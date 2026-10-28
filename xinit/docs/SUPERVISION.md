# Supervision Model

This describes how xinit keeps services running and why it is shaped this way.
[INIT.md](INIT.md) is the contract (commands, service fields, defaults); this
is the design behind the scanner, its state, and its control plane.

## The idea borrowed from s6

A pidfile written by a process that has already exited cannot be trusted. If
the daemon dies and the kernel recycles its pid, a reader reports a healthy
service that is gone, and `stop` signals whatever now owns that pid. At PID 1
that is a real hazard.

In s6 and runit, the supervisor process is the source of truth, not a pidfile.
The entity that knows whether a service is alive is always running and is the
same entity that owns and reaps the child, so state cannot go stale. xinit
takes that one idea and keeps the rest small.

## The scanner

`xinit supervise SERVICE` and `xinit scan [SERVICE|TARGET]` are one scanner.
It holds a set of `ServiceUnit`s (one for `supervise`; a target's services, or
a service plus its dependencies, for `scan`) and on every wakeup reconciles
each unit toward its desired state:

- A unit whose desired state is `up`, whose process is not running, and whose
  backoff gate has elapsed is (re)spawned.
- A service leader exit stops and reaps the remaining owned process group,
  then runs `finish()` and schedules a respawn or marks the unit stopped.
- Group cleanup can reap other units' children. The scanner reconciles those
  exits before starting replacements, so no sibling exit is lost.
- On `SIGTERM` or `SIGINT` the scanner stops its units in reverse dependency
  order, reaps the owned groups, and exits.

Every unit reconciles against one start-of-pass snapshot, so gating reads
consistent dependency states regardless of iteration order. The scanner is
the only writer of the status JSON for the units it owns.

### Unit states

```text
pending -> starting -> running -> dead -> running ...
                          \-> finishing -> stopped
```

- `pending`: not yet started; the first start waits for the dependency gate.
- `starting`: spawned, waiting for a `readiness: "notify"` byte or for a
  `ready()` hook to answer true; the hook is evaluated once per scanner pass.
- `running`: up (and ready, unless a notify timeout promoted it).
- `dead`: the child exited and a backoff respawn is scheduled. Callers see
  `dead` so they can tell a unit awaiting respawn from one that is up.
- `finishing`: the service's `finish()` hook is running after its child
  exited.
- `stopped`: down, either requested or because the restart policy declined.

### Backoff without blocking

Backoff is a per-unit `next_ms` gate checked on each pass, not a sleep. The
scanner sleeps in `unix.wait_pid1_event(timeout:)` until the soonest gate and
wakes early on a signal or child exit, so an idle tree does not spin and
backing one unit off never delays stopping or starting another. Units blocked
on the dependency gate are left out of that deadline. Units in `starting` poll
readiness every 100 ms, whether the signal is a notify byte or a `ready()` hook. The restart fields are in
[INIT.md](INIT.md#restart).

### Dependency gating and readiness

The gate and the readiness contract are in [INIT.md](INIT.md#scanner-and-control).
A gated unit stays `pending` and its wakeup comes from the dependency's own
transition, not from a timer.

## Control plane

While a scanner owns a run directory, `start`, `stop`, `restart`, and
`reload` post requests to its inbox instead of acting on the process
([INIT.md](INIT.md#scanner-and-control)). Without a scanner, the one-shot
`start` path records the child's kernel start time when available. Every status
read probes liveness with signal 0 and compares any recorded start time against
the kernel: a pid that is gone, or alive with a different start time
(recycled), reconciles to `dead`. The scanner does not need that check,
because it clears a unit's pid the instant its child exits.

## The inittab engine

The PID 1 inittab engine (`spawn_entries` and `run_pid1`) is a second,
specialized scanner. It shares the backoff and respawn timing gate
(`spawn_due`) with the service scanner and keeps its own policy: ttys,
poweroff on exit, launch limits, flat respawn delay, the
`sysinit`/`wait`/`shutdown` phases, restart by exec, and
halt/poweroff/reboot.

Inittab entries are deliberately not synthetic `ServiceUnit`s. XSH has no
first-class closures, so a shared reconcile could not take the spawn mechanism
as a strategy; it would branch on inittab-only fields while the two engines
gate differently (raw-pid tracking versus a desired-state machine). Merging
them would complicate the service model and the boot-critical PID 1 tests for
deduplication alone.

## Lifecycle qualification

The [disposable guest driver](../tests/README.md) exposed two ownership failures
on Laputa `4af7664`. Killing a service leader left its descendant alive, so
replacement instances collided with the descendant's exclusive lock. Normal
scanner shutdown left exited leaders as zombies after the scanner returned.
The scanner now reaps those groups before discarding their ownership.

The reduced `crash` guest replay and
`test_crashed_leader_group_cleanup_precedes_finish_and_respawn` both reject the
original implementation. Both also reject a repair that invokes group cleanup
with an empty group list. The native replay uses installed Unix fakes and has
no fallback to live host operations.

The XSH-only replay also passes inside the actual x86_64 KVM self-hosting VM.
The canonical scanner reaps the same-group descendant before finish and respawn.
A private runtime copy with exactly one cleanup call changed to an empty group
list exposes `surviving-owned-descendant` for the same `crash` prefix. The VM
emits `LAP34_VM_OK` only after both cases clean up their owned groups. The
canonical source remains read-only throughout the negative qualification.

On Linux x86_64 in the existing `xsh-test` Docker image, the repaired scanner
passes seeds 1, 7, and 43 with six actions each under both SIGTERM and SIGINT.
The reduced `crash` and `restart` replays also pass both signals. The guest
checks real descendants, service exclusivity, a foreign process's identity,
readiness success and failure, restart count, finish hooks, reverse shutdown,
and absence of surviving groups or zombies.

These checks use the supplied fixed XSH tools from `xinit-optional-condition`,
whose source base is `7261b04208fb16bb061c346c47259c8d0de76712`. Unfixed
`f286c59e4` and pre-Deser `7577228454b70be816066fe20d97443dd05dae11` fail
compiling unchanged xinit before any guest lifecycle assertion.

Further qualification below covers namespaced PID 1 dispatch, controlled
startup and finish interruptions, bounded reduction, and test-switch separation.
SIGKILL of the scanner, disk power loss, and other targets retain independent
limitations.

## Service configuration qualification

`service_from_record` remains the single normalization boundary. It rejects
unknown fields, conflicting log declarations, missing required fields, explicit
null, invalid names or variants, negative ranges, and invalid dependency lists.
The graph check rejects duplicate identities, missing dependencies, and cycles.
`inspect` and `start-plan` render that same normalized `Service`; they never
render the command's argv or environment.

The pre-change implementation accepts the malformed `typo: true` declaration.
The kept regression rejects it before creating runtime state. Native coverage
includes malformed shapes and values, graph failures, normalized defaults,
and read-only output.
All six installed service modules and `docs/demo-service.xsh` pass production
`xinit check` without declaration changes.

The Linux x86_64 disposable guest's seed 1 passes six lifecycle actions under
both SIGTERM and SIGINT after checking malformed declarations, redacted
inspection, and ordered planning. Those read-only commands leave runtime paths
and worker events absent. The proof uses the same supplied fixed XSH tools as
the lifecycle qualification above. Executable service modules retain their
trusted module-level effects; no inert external-data format is introduced.

## Test-control qualification

Inittab launch delay and launch limit now enter through one typed
`InittabPolicy`, using nonnegative CLI values rather than test environment
variables. Test controls require the single non-PID1 opt-in and are disabled
for actual PID 1. Native regressions cover policy range rejection, retired environment overrides, inert fake-PID
controls, and rejection of the retired non-PID1 alias.

The production scanner passes guest seed 7 under SIGTERM and SIGINT with
`XSH_UNIX_DRY_RUN=1`, `XINIT_TEST_FAKE_PIDS=1`, and `XINIT_TEST_MAX_EVENTS=0`
present but no opt-in. It stays alive, and control requests queue to the live
scanner rather than taking the direct process path.

The fake-PID adapter remains explicitly test-controlled. A minimal native
probe confirms that installing `test.mock` for `process.kill` does not dispatch
that mock: signal 0 on an absent PID still returns an error and records no call.
The adapter is confined to explicitly opted-in native fixtures.
No XSH source or runtime provider was changed.

## Pure restart policy qualification

The existing spawn, dependency, deadline, and delay helpers retain one owner.
A private pure `restart_delay` selects the stable-after delay from immutable
service settings and explicit current-delay and time observations. It reads no
clock. Backward observations preserve the current delay rather than resetting it.

Capped delay escalation now checks the cap before multiplication. The old
helper overflows for the valid delay 4611686018427387904 and cap
9223372036854775807 instead of saturating. The retained regression fails on
that implementation and passes with the cap-first calculation. Uncapped integer
overflow continues to fail explicitly.

Native tables cover the stable-after boundary, retry saturation, zero delay,
required and optional dependency gates, first-start-only gating, backward time
observations, and invalid input. A compile-negative probe rejects a hidden
`time.now()` in the pure selector. Test-owned source renames the CLI entry before
calling the actual private helpers, with an exact-entry assertion that fails
before execution if the entry changes. There are no new exports, policy types,
callbacks, or production test switches.

Production guest seed 1 passes six actions under both SIGTERM and SIGINT with
the existing ownership and poisoned-environment checks. Clock-source
qualification follows below.

## Elapsed clock qualification

XSH's authored `time.monotonic` contract specifies nanoseconds, a process-local
opaque origin, and non-backward progress. Its native implementation uses a
process-local `OnceLock<Instant>`. xinit now converts those samples to milliseconds
at one private boundary for all six former elapsed wall-clock reads. Calendar
state and saved kernel process-start identity remain separate.

Native conversion and sampler-bracketing tests reject a mutation that returns
wall epoch milliseconds. Explicit observations cover readiness timeout, restart
deadlines, and fresh zero-origin state. Production Docker replay
`crash,scanner-restart,timeout-ready` passes both shutdown signals, including
replacement of the scanner while retaining its run directory. No process-local
deadline is serialized. The guarded fixture passes in the actual x86_64 KVM
self-hosting VM: forward and backward wall steps preserve readiness, restart,
and forced stop budgets; cleanup restores the guest wall clock. The supervisor
acknowledges QMP stop before the resume marker, pauses three host seconds, and
acknowledges continue. Around the fixture's two-second sleep, the guest reports
2001 monotonic milliseconds and 2000 wall milliseconds. This backend excludes
the host pause from those guest clock deltas; other backends remain unqualified.

## Controlled interruption qualification

A startup interruption exposed another lifecycle defect: shutdown called stop
and finish for a dependent that never started. `kill_unit` now skips units with
no owned PID and no active logical state. The kept native regression fails on
the previous implementation and passes with that guard. It preserves cleanup
for running oneshots whose process has already exited.

The full native suite passes 35 tests without skips. Real Docker cases pass
SIGTERM and SIGINT at the scanner ownership/startup barrier and while a finish
hook is held. The hook returns before shutdown completes. Namespace census
rejects surviving tasks and zombies, including children without birth records.
Fixed seeds 1, 7, and 43 pass six actions each with both shutdown signals.
The descendant now closes its inherited readiness notifier, so the explicit
`close-ready` replay exercises genuine pipe closure.

Actual namespaced PID 1 passes HUP, USR1, USR2, INT, and TERM dispatch. HUP execs
the restart hook as PID 1. The other signals reach the correct halt, poweroff,
or reboot syscall and return its distinct EPERM diagnostic. Containers have
zero effective capabilities. Lifecycle hooks independently verify that owned
leaders and descendants were reaped first. Actual PID 1 ignores poisoned test
overrides and never writes the forbidden action-log file.

With an intentionally broken empty-group cleanup, the automatic reducer starts
from `restart,crash,stop-start`, observes prefix `restart,crash`, and reduces it
to `crash` in two trials. The empty replay passes. Phase `term` and invariant
`duplicate-service` remain identical. Reduction permits at most eight trials
within a shared 120-second trial budget and rejects infrastructure failures.
The candidate is restored after this negative qualification. No production
manager, service schema, dependency, or XSH runtime change is introduced.

## Open work

- Notify readiness is polled on a bounded 100 ms cadence; surfacing it as a
  `wait_pid1_event` event would remove the poll.
- Dependency-triggered restart (restarting a dependent when a `need`
  dependency goes down) is not done, matching first-start-only gating.

## Non-goals

Deliberately not borrowed, to keep xinit small and inspectable:

- **s6-rc offline compilation.** xinit resolves dependencies at runtime from
  service files, which is more inspectable for a small system.
- **execline.** XSH already gives structured, no-shell-string execution at
  PID 1.
- **A separate logging service layer (runit-style `log/` dirs).** xinit owns
  log capture in-process. Rotation and retention extend the built-in log path
  rather than adding a per-service logger to wire by hand.
- **Socket activation.** A systemd concept, not an s6 one, and out of scope.
