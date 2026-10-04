# Supervision Model

This describes how xinit keeps services running and why it is shaped this way.
`INIT.md` is the user-facing contract (commands, service fields, defaults);
this is the design behind the scanner, its state, and its control plane.

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
- A child exit marks its unit dead and either schedules a respawn through the
  unit's restart policy or marks it stopped.
- On `SIGTERM` or `SIGINT` the scanner stops its units in reverse dependency
  order and exits.

Every unit reconciles against one start-of-pass snapshot, so gating reads
consistent dependency states regardless of iteration order. The scanner is
the only writer of the status JSON for the units it owns.

### Unit states

```text
pending -> starting -> running -> dead -> running ...
                          \-> finishing -> stopped
```

- `pending`: not yet started; the first start waits for the dependency gate.
- `starting`: spawned, waiting for a `readiness: "notify"` byte.
- `running`: up (and ready, unless a notify timeout promoted it).
- `dead`: the child exited and a backoff respawn is scheduled. Callers see
  `dead` so they can tell a unit awaiting respawn from one that is up.
- `finishing`: the service's `finish()` hook is running after its child
  exited.
- `stopped`: down, either requested or because the restart policy declined.

### Backoff without blocking

Backoff is a per-unit `next_ms` gate checked on each pass, not a sleep. After
a crash the delay starts at `delay_ms` and doubles per successive crash up to
`max_delay_ms`; a run that stayed up for `stable_after_ms` resets it. The
scanner sleeps in `unix.wait_pid1_event(timeout:)` until the soonest gate, and
wakes early on a signal or a child exit, so an idle tree does not spin and
backing one unit off never delays stopping or starting another. Units blocked
on the dependency gate are left out of that deadline.

### Dependency gating

A unit's first start waits until its `need` dependencies are `running` and its
`uses` and `after` dependencies are running or `stopped` (settled).
Dependencies outside the scanned set, including the built-in facilities,
impose no gate. Respawns are not re-gated, and a dependency going down does not
stop or restart a running dependent.

### Readiness

The default is `ready()` polling: a longrun is ready once spawned, or once its
exported `ready()` returns true within `ready_timeout_ms`. A
`readiness: "notify"` service is spawned with an inherited pipe whose write end
is `NOTIFY_FD`; the unit stays `starting` until the service writes a byte, or
until `ready_timeout_ms`, when it becomes `running` with `ready` false rather
than wedging. Stop sends `TERM` to the process group, then `KILL` after the
service's `stop_timeout_ms`, unless the service exports `stop()`.

## Control plane

While a scanner owns a run directory, marked by a live
`${XINIT_RUN_DIR}/scanner.json`, `start`, `stop`, `restart`, and `reload` do
not act on the process. They post a desired-state request (`up`, `down`,
`restart`, `reload`) to `${XINIT_RUN_DIR}/inbox/SERVICE`, and the scanner
drains the inbox on its next pass. Without a live scanner, `start` and `stop`
act directly. That one-shot `start` path records the child's kernel start
time, and every status read checks the saved pid against the kernel: a pid
that is gone, or alive with a different start time (recycled), reconciles to
`dead`. The scanner does not need that check, because it clears a unit's pid
the instant its child exits.

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
