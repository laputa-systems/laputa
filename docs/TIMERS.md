# Timers

`laputa-timers` is a small supervised scheduler. One foreground XSH process
owns every job, and xinit supervises only that process. It is not PID 1 and not
a second init system: no boot-critical service depends on it, a broken job
definition never holds back boot, rescue, or login, and stopping the service
stops its jobs. Nothing here schedules backups or pruning; a job definition can
request either once a later slice adds the command.

The roadmap entry is [R7](ROADMAP.md#r7-backups-timers-and-persistent-diagnostics).

## Ownership and paths

| Path | Owner | Purpose |
|---|---|---|
| `/etc/laputa/timers/jobs.d/NAME.json` | image/profile generation | Immutable job definitions. The scheduler only reads them. |
| `/var/lib/laputa-timers/state.json` | scheduler | Durable per-job last/next results and counters. |
| `/var/lib/laputa-timers/cancel/NAME` | operator | Cancellation marker; its presence cancels one job. |
| `/run/laputa-timers/status.json` | scheduler | Live inspection snapshot; lost at reboot. |
| `/run/laputa-timers/scheduler.lock` | scheduler | Exclusive lock; a second scheduler refuses to start. |
| `/var/log/laputa-timers/current` | xinit | Captured scheduler and job output, copied-truncated by xinit. |

The maintained profile mounts its administered `/etc` from the state disk
over the generation's `/etc`, so its job definitions are provisioned there with
the rest of the generation's static configuration, exactly like
`/etc/inittab`. A profile without a state disk reads the generation's `/etc`
directly. The scheduler never writes a job definition.

## Job definition

One JSON object per file, `format` `laputa-timer-job-1`. The file stem must equal
`name`, and names match `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}`.

| Field | Meaning |
|---|---|
| `format` | Required, exactly `laputa-timer-job-1`. |
| `name` | Required; must equal the file stem. |
| `schedule` | `{kind: "interval", every_ms: N}` or `{kind: "calendar", hour: H, minute: M}` in UTC. |
| `command` | Required argv list, 1 to 64 strings. `command[0]` must be an absolute path. No shell is involved. |
| `timeout_ms` | Optional, `0` (none) to 86400000. A timed-out attempt gets `TERM`, then `KILL` after two seconds. |
| `overlap` | Required: `skip` or `queue`, chosen per job. |
| `missed` | Optional, default `coalesce`: `coalesce` or `skip`. |
| `retries` | Optional `{max: 0..10, delay_ms: 0..3600000}`; total attempts are `1 + max`. |

Unknown keys at any level, a wrong type, a missing required field, and an
out-of-range value are all invalid. An invalid definition is reported in the
status snapshot and its log line; it is never run, and the other jobs keep
working. Duplicate names are reported, and the first definition in file-name
order wins. Jobs run with `cwd` `/`, stdin `/dev/null`, and the scheduler's
standard output, so their output lands in the xinit capture. Each run also
receives `LAPUTA_TIMER_NAME`, `LAPUTA_TIMER_ATTEMPT`, `LAPUTA_TIMER_MISSED`,
`LAPUTA_TIMER_SCHEDULED_WALL_MS`, `LAPUTA_TIMER_START_WALL_MS`, and
`LAPUTA_TIMER_START_MONO_MS`.

Limits: 64 definitions, 64 argv entries, interval 1 s to 365 days. There is no
global concurrency cap; one process per due occurrence is the only bound.

## Scheduling semantics

Interval jobs are measured on the process monotonic clock
([`lib.monotonic`](https://github.com/laputa-systems/xsh/blob/master/core/lib/monotonic.xsh)):
the first run is one interval after the scheduler arms, and each later
deadline is `start + every_ms` from the pass that started it. A wall-clock
correction while the scheduler runs never moves an interval deadline.

Calendar jobs are UTC wall times. The next occurrence is the next `hour:minute`
strictly after the last decision; a daily schedule therefore stays on its wall
grid and does not drift with monotonic elapsed time. UTC is deliberate: the
image has no timezone database, and a local-time schedule would depend on
`/etc/localtime` policy that does not exist.

Overlap, chosen per job:

- `skip`: a due occurrence of a job that is still running is skipped and
  counted in `skipped_overlap`.
- `queue`: one occurrence is held behind the running one. When the run
  finishes, the held occurrence starts immediately. A further occurrence while
  one is already held is skipped and counted in `skipped_overlap`.

Missed runs, chosen per job with `missed`:

- `coalesce` (default): any number of missed occurrences produce at most one
  run. An interval catch-up runs now and re-anchors the next deadline to
  `now + every_ms`; a calendar catch-up runs once and advances to the next
  occurrence after now. The collapsed count is reported in `coalesced`.
- `skip`: missed occurrences are discarded. If the scheduler was late by at
  least one whole interval (or one whole calendar day), the pending occurrence
  is discarded too and the next is computed from now. The discarded count is
  reported in `skipped_missed`. A late-but-not-missed occurrence still runs.

Retries: a failed, signalled, or timed-out attempt is retried after
`retries.delay_ms` on the monotonic clock while attempts made are at most
`retries.max`. A queued occurrence supersedes a pending retry of the failed
occurrence. The retry sequence is in memory only: a scheduler restart or reboot
ends it and the next due occurrence starts fresh. Outcomes are `ok`, `failed`,
`signaled`, `timeout`, and `cancelled`; `cancelled` is not counted as a
failure.

Cancellation: `xsh /usr/lib/laputa/timers.xsh cancel NAME` writes
`/var/lib/laputa-timers/cancel/NAME`; `resume NAME` removes it. A cancelled job
starts nothing and a running attempt is terminated with `TERM` and then `KILL`
after two seconds. A queued occurrence or pending retry is dropped. Because the
marker is on the state disk, cancellation survives a reboot. Resuming re-arms
the job with a fresh interval or the next calendar occurrence.

## Clock corrections and VM pauses

Three clocks are kept separate:

- **Monotonic** (`lib.monotonic.Reading`) is the authority for interval
  deadlines and retry delays. It is never persisted.
- **Wall** (`time.now`, epoch milliseconds) is the authority for calendar
  deadlines and is the only clock written to the state file.
- **Startup wall** is a one-time estimate. An interval job that was last
  started before a reboot uses the wall gap to keep its remaining budget, or to
  decide that at least one interval passed while the machine was down. A
  backward wall reading is clamped to zero and never triggers a catch-up.

At every pass the scheduler compares the wall and monotonic deltas since the
previous pass. With a two-second tolerance it records:

- `steady`: neither clock moved measurably;
- `gap`: both moved together, so the process was not scheduled (a VM pause
  whose guest clock advances, or a long blocked pass);
- `wall-forward`: only the wall moved; calendar schedules are re-evaluated and
  interval deadlines are untouched;
- `wall-backward`: the wall moved backward; calendar schedules are re-anchored
  to the corrected wall and intervals remain untouched.

A daily calendar anchor more than one day in the future can only follow a
backward step, so it is re-anchored instead of waiting for a past wall time.
A forward step makes at most one occurrence due, then the next occurrence is
computed from the corrected wall. A VM pause that freezes every guest clock is
not observable inside the guest and moves no deadline; the scheduler simply
resumes with the remaining budget. No pause or step can produce a catch-up
burst.

## Inspection

Local:

```sh
xsh /usr/lib/laputa/timers.xsh status          # one line per job
xsh /usr/lib/laputa/timers.xsh status --json   # the normalized snapshot
xinit status laputa-timers                     # the service line with jobs= due= running=
```

Remote, through the existing administration library and the fixed remote
program's `run` operation:

```xsh
use system.remote

let program = remote.remote_program(root)?
with session = remote.remote_connect(target)? {
  let reply = remote.remote_run(session, program, ["/usr/bin/xsh", "/usr/lib/laputa/timers.xsh", "status", "--json"])?
}
```

`tests/integration/timers_guest.py` calls the same fixed program's `run`
operation through its virtio-serial agent, so the transport is the already
qualified SSH path rather than a new protocol.

The packaged scheduler links the pinned core `lib/monotonic.xsh` beside itself
(`/usr/lib/laputa/lib/monotonic.xsh`), so this path needs no
`XSH_MODULE_PATH`. Remote inspection is the same read-only status call, not a
second status protocol.

The snapshot reports, per job: `schedule`, `overlap`, `missed`, `state`
(`idle`, `due`, `running`, `queued`, `retry`, `cancelled`), `last` (start and
finish wall times, outcome, exit code), `next` (wall estimate, remaining
milliseconds, and whether it came from `calendar`, `monotonic`, `queued`,
`retry`, or the `startup` estimate), `retry` position, and counters. Invalid
definitions appear in `invalid` with their file and message. `state.json`
carries only the durable subset; `next_wall_ms` for an interval job is an
estimate derived from the live monotonic deadline and is not persisted.

## Failure contract

The scheduler does not promise exactly-once side effects. A crash, reboot,
power loss, or clock correction can repeat a run or skip one, within the
at-most-one-catch-up rules above. Every job must therefore be idempotent or
reconcile its own effects on start. The durable state is replaced atomically
and fsynced at the end of each pass that changed it, so a crash between a spawn
and that write can lose one start observation; the resulting catch-up is still
bounded by one run per job. A damaged state file
fails the scheduler loudly instead of silently resetting schedules. Counters
are observations, not an audit log. Job standard output shares the service's
single bounded xinit log, and xinit's copy-truncate rotation can lose a write;
this is not a lossless event log.

## Verification

- `tests/system/timers.xsh` covers the pure decisions with an injected clock:
  interval wait/start/coalesce/skip, calendar next and rollover, downtime
  coalescing, forward and backward wall steps, overlap, bounded retries,
  cancellation, outcomes, durable state transitions, and definition
  validation.
- `tests/integration/timers_guest.py` runs the rebuilt `qemu-maintained` image
  under KVM: a three-second interval job, a bounded-retry job, cancel/resume,
  a 20-second QMP pause, a cold boot of the same state disk with a coalesced catch-up, an xinit
  restart that reloads state, and the remote `run` path.
