# XSH Init

`xinit` is a pure XSH init and service supervisor script, installed as
`/usr/bin/xinit` with `/init` linking to it. Inittab commands, boot and
shutdown hooks, and service modules are ordinary XSH or executable commands.
PID 1 mechanics live in `xinit.xsh` and the XSH `unix` and `linux` module
APIs it calls; `xsh --pid1` is not supported.

This is the contract for inittab authors and service authors. The
[supervision model](SUPERVISION.md) explains the design behind the scanner.
The command list is in the [README](../README.md); `xinit help` prints it.

## Paths

With no argument, `xinit` runs as PID 1 on the inittab named by
`XSH_INIT_INITTAB`, default `/etc/inittab`. It refuses to run unless
`getpid() == 1`. The typed inittab execution policy accepts `--respawn-delay-ms N` (default 1000)
and `--launch-limit N` (default 0, unlimited). Both are `UInt` values. They apply
to respawn entries; the inittab line format is unchanged. Legacy
`XSH_INIT_TEST_MAX_RESPAWNS` and `XSH_INIT_TEST_RESPAWN_DELAY_MS` are ignored.

- `XINIT_SERVICE_DIR`, default `/usr/lib/xinit/services`.
- `XINIT_RUN_DIR`, default `/run/xinit`.
- `XINIT_LOG_ROOT`, default `/var/log`.

## Inittab

Each non-empty line is `id:runlevels:action:command`. `runlevels` is parsed
for compatibility and ignored. `command` is split with XSH argv parsing, so
quotes and escaped spaces work.

- `sysinit`: run synchronously before services.
- `wait`: run synchronously after `sysinit`.
- `once`: start once and do not restart.
- `respawn`: supervise with a flat launch delay.
- `poweroff`: start once; when it exits, stop owned process groups and power off.
- `restart`: exec on the restart lifecycle.
- `shutdown`: run synchronously during shutdown after owned process groups stop.

Lifecycle signals: `SIGHUP` restarts, `SIGUSR1` halts, `SIGUSR2` and `SIGINT`
power off, `SIGTERM` reboots. Child exits are drained before lifecycle signals.
On Linux `xinit` becomes the child subreaper. Halt, poweroff, and reboot send
`TERM` then `KILL` (after 2 seconds) to every remaining process before the
kernel call.

```text
::sysinit:/usr/lib/init/rc.boot
::restart:/usr/bin/xinit /etc/inittab
::shutdown:/usr/lib/init/rc.shutdown
ttyAMA0::poweroff:/bin/xshi --no-config
tty1::respawn:/bin/getty 38400 tty1
```

The serial console is `ttyAMA0` on aarch64 `virt` (PL011) and `ttyS0` on
x86_64. Example hooks: [boot](minimal-rc.boot.xsh),
[shutdown](minimal-rc.shutdown.xsh).

## Services

`xinit start demo` and `xinit supervise demo` load
`${XINIT_SERVICE_DIR}/demo.xsh`. Each file exports one `service` record; see
[demo-service.xsh](demo-service.xsh), and `packages/*/service.xsh` for the
installed ones. `xinit check` validates the files and the dependency graph.

`service_from_record` in `xinit.xsh` constructs the normalized `Service` used
by validation, planning, and execution. Unknown fields are errors at the top
level and inside `dependencies`, `restart`, `log`, and `resources`. Supplying
both `logging` and `log` is an error. A present field must have its declared
type. Explicit `null` never selects a default.

`name` and `command` are required. Names, targets, and dependency names must
match `[A-Za-z0-9][A-Za-z0-9_.-]*`. A service cannot depend on itself. Duplicate
names within a list, duplicate service identities, and dependencies appearing
in both `need` and `uses` are errors. All entry points reject invalid service
values before application. `check` also rejects missing dependencies and cycles.

| Field | Meaning |
|---|---|
| `name`, `command` | Required service name and typed `Command`. A `start()` hook still requires a command declaration. |
| `kind` | `longrun` (default), `oneshot`, or `scripted`. Other values are errors. |
| `targets` | Targets selected by `boot [TARGET]`; defaults to `[]`. The boot command defaults to target `boot`. |
| `dependencies` | `need`, `uses`, `after`, `before`. |
| `restart` | `mode`: `always`, `on_failure`, `never`; default `on_failure` for `longrun`, `never` otherwise. `delay_ms`, `max_delay_ms`, `stable_after_ms`. |
| `readiness` | `"auto"` (default), or `"notify"` for a longrun. |
| `ready_timeout_ms`, `stop_timeout_ms` | Defaults 5000 and 200. |
| `logging` | `"append"` (default) or `"off"`. |
| `log` | `{mode, max_size, keep}`; `mode` is required and must be `"append"` or `"off"`. Conflicts with `logging`. |
| `resources` | `{cpu_max: N}`. |

Timing values, log size and retention, and CPU percentages must be nonnegative.
`restart.max_delay_ms` must be zero or at least `restart.delay_ms`. Zero retains
its documented meaning for uncapped backoff, immediate restart, and disabled
rotation. Defaults apply only when a field is absent.

`xinit inspect SERVICE` prints normalized JSON with the module's source path.
The entire command, including argv and environment, is replaced by `"redacted"`.
`xinit start-plan SERVICE` prints the same records in dependency start order.
These commands and `check` do not launch services or write runtime state.
Executable availability, log permissions, and cgroup permissions remain
execution preconditions checked when a service starts.
Service modules are trusted executable XSH: loading them can run module-level
effects. Inspection does not confine or make module evaluation inert. There is
one module per service and no additional configuration layering or merge order.

A module may also export lifecycle procs. `start()` and `stop()` replace the
default spawn and stop, `reload()` replaces the `SIGHUP`, `ready()` gates
dependents, `status()` appends text to the `status` line (a failing hook appends
`status-error=MESSAGE` and the command still succeeds), and `finish()` runs after the
instance exits, on a clean stop or a crash, while the unit reports
`finishing`. The scanner does not call stop or finish for a pending unit that
never started, or repeat finish after an already processed crash. A completed
oneshot remains a running logical unit until stopped. Signatures are in
`ServiceFile` in `xinit.xsh`.

### Test controls

`XINIT_TEST_ALLOW_NON_PID1=1` is the only non-PID1 test opt-in. It enables test
controls only when the process is not PID 1. Actual PID 1 ignores every test
control, even when that opt-in is set. No environment variable installs XSH's
native Unix or Linux fake providers.

The remaining explicitly controlled fields are:

- `XINIT_TEST_FAKE_PIDS`: preserves fake saved PIDs and bypasses live scanner
  detection for native fixtures. It also selects their synthetic cgroup label.
- `XINIT_TEST_MAX_EVENTS`: bounds scanner events for native fixtures.
- `XINIT_TEST_EXIT_WHEN_IDLE`: returns when a bounded inittab fixture is idle.
- `XINIT_TEST_FAST_SHUTDOWN`: skips the owned-group TERM grace in an inittab fixture.
- `XINIT_TEST_SKIP_FINAL_CLEANUP`: omits the Linux-wide cleanup in an inittab fixture.
- `XINIT_TEST_ACTION_LOG`: records the selected final action instead of invoking it.

Those fields are inert without the opt-in. The old `XSH_UNIX_DRY_RUN`,
`XSH_INIT_TEST_ALLOW_NON_PID1`, `XSH_INIT_FAST_SHUTDOWN`,
`XSH_INIT_FINAL_CLEANUP`, and other `XSH_INIT_TEST_*` controls are ignored.
The production `XSH_INIT_INITTAB` path setting remains supported.

The explicit fake-PID adapter remains necessary because the qualified XSH fake
provider cannot supply fake-aware `process.kill(..., signal: "0")`, process
start identities, or scanner liveness. Its `test.mock` dispatcher currently
supports DNS and networking, not those process operations. Removing that adapter
requires a qualified XSH observation primitive; it is not a production fallback.

### Dependencies

- `need`: required; `start SERVICE` starts them first and aborts on failure.
- `uses`: optional; a start failure is tolerated. Named `uses` because `use`
  is an XSH keyword.
- `after`, `before`: ordering only.

The built-in facility names `logger`, `net`, `dns`, and `firewall` need no
service file. Any other dependency must resolve to a service file; cycles and
missing dependencies are errors. `boot` starts all services declaring the
target. `stop` refuses while running services `need` the target, unless a
scanner owns the run directory.

### Scanner and control

`supervise SERVICE` and `scan [SERVICE|TARGET]` are one scanner. `supervise`
holds one unit; `scan` holds a target's services, or a service and its
dependencies. The scanner owns and reaps its children, writes their status
JSON, and on `SIGTERM` or `SIGINT` stops them in reverse dependency order.
When a service leader exits, the scanner stops and reaps its remaining process
group before `finish()` and respawn. Scanner shutdown reaps owned groups before
returning. Group cleanup allows `stop_timeout_ms` for TERM and 100 ms after KILL.
A group surviving that bound produces an `xinit-cleanup` error.

While a live `${XINIT_RUN_DIR}/scanner.json` marks a scanner,
`start`/`stop`/`restart`/`reload SERVICE` post a request to
`${XINIT_RUN_DIR}/inbox/SERVICE` instead of acting, and the scanner applies it
on its next pass. Without a scanner, `start` and `stop` act directly.

A scanner gates each unit's first start. A `need` dependency must be
`running`; `uses` and `after` dependencies may also be `stopped`. Dependencies
outside the scanned set impose no gate. Respawns are not re-gated, and a
dependency crashing does not stop a running dependent.

### Restart

After a crash the scanner waits `delay_ms`, doubles the delay on each further
crash up to `max_delay_ms` (`0` is uncapped), and resets it to `delay_ms` after a
run of at least `stable_after_ms`. `delay_ms: 0` restarts immediately. A unit
awaiting respawn reports `dead`.

Elapsed readiness, backoff, and inittab gates use monotonic milliseconds from
the current process. XSH supplies process-local monotonic nanoseconds, converted
once at the private clock boundary. No deadline or elapsed origin is persisted.
A new scanner initializes fresh gates from its command and inbox rather than
reusing an old process's deadlines. Saved process-start identity remains a
separate kernel observation.

After a VM pause, reconciliation follows the guest monotonic clock. An expired
gate is due on resume; a clock that excludes the pause retains its remaining
budget. No host-duration accounting is assumed. The qualified x86_64 KVM guest
excludes a three-second host QMP pause from its observed elapsed clock delta.

### Readiness

By default a longrun is ready once spawned, or, if it exports `ready()`, when
that returns true within `ready_timeout_ms`. The scanner evaluates `ready()`
once per pass while the unit is `starting`, so a hook that stays false never
stalls the scanner, rescue or login; it must return promptly and is not run in a
loop. The one-shot `xinit start` path, which has no scanner to protect, still
waits for the hook. With `readiness: "notify"` the scanner passes a pipe whose fd
number is in `NOTIFY_FD`; the unit is `starting` until the service writes any
byte to it. On timeout the unit becomes `running` with `ready` false. `status`
and `list` report readiness.

Four levels stay distinct, and only the first three are ever reported:

| Level | Where it shows | Meaning |
|---|---|---|
| Process running | `state`, `pid` | The leader was spawned and has not exited. |
| Ready | `ready` | The notify byte arrived or `ready()` returned true: the service says it can serve, for example that its socket is bound. |
| Configured | `status()` text such as `lease=bound` | The service's own state, read by its `status()` hook. |
| Reachable | never | Nothing here checks that the Internet or a remote host is up. |

`need` waits for `running`, which for a notify service is the readiness byte. A
service file named `logger`, `net`, `dns` or `firewall` is an ordinary service
and takes precedence over the built-in facility of that name; without such a
file the name resolves to nothing and gates nothing.

### Stop and reload

Without a `stop()` hook, stop sends `TERM` to the saved process group, then
`KILL` after `stop_timeout_ms`. `reload` runs `reload()` if exported, otherwise
sends `SIGHUP` to the saved process group; it does not change state.

### Logs

Append logging is owned by `xinit`: stdout and stderr go as raw combined bytes
to `${XINIT_LOG_ROOT}/SERVICE/current` (directory `0755`, file `0600`). If the
file cannot be created or opened, start fails. `logging: "off"` disables
capture and shows as `log=none` in status.

Stdout is the only channel a service has: it should write one line per record
and never send its own diagnostics to a syslog socket. The file is opened
`O_APPEND` before the spawn, so each write lands at the current end. Rotation is
copy-then-truncate, at service start and on every scanner pass once the file
reaches `log.max_size` (default 1 MiB, `log.keep` copies, default 3): the
content is copied to `current.1`, older copies shift up, and `current` is
truncated in place. The service keeps writing to the same inode, which is why a
live writer is undisturbed. A removed `current` is not noticed by `xinit`: the
service keeps writing to an unlinked inode without an error, so a service that
cares must watch its own output (`syslogd` does, and exits so the supervisor
reopens the file). The reference modules [syslog-service.xsh](syslog-service.xsh)
(service `logger`) and [dhcp-service.xsh](dhcp-service.xsh) (service
`dhcp-IFACE`) show a longrun with `readiness: "notify"`, `restart.mode:
"always"`, a `stop_timeout_ms` of 2000 and a `status()` hook.

`current` rotates to `current.1` and shifts older copies up to
`current.<keep>` when it reaches `max_size` bytes; defaults are 1 MiB and 3.
`max_size: 0` disables rotation. Rotation runs before each start and, under a
scanner, each pass by copy-truncate, so a write between copy and truncate may
be lost. There is no compression or timestamping. A failed rotation degrades
instead of failing its caller: the current file stays in place, a service
still starts, and the scanner stays alive to retry on the next pass. Log
pressure itself stays visible at the writers (a syslog receiver counts its
blocked and failed sinks) rather than in the supervisor.

### Resources

`resources: {cpu_max: N}` limits the process tree to N percent of one CPU
through cgroups v2, matching `run --cpumax`. macOS accepts it as a no-op. No
other cgroup policy exists.

### Status

```text
demo running pid=1000 ready=true log=append desired=up restarts=0
```

`supervisor=PID` and `cgroup=PATH` are appended when set. Saved status is
reconciled against the kernel on every read: a vanished or recycled pid
becomes `dead` with the pid cleared, and completed `oneshot`/`scripted`
services with pid 0 stay `running`. See the
[control plane](SUPERVISION.md#control-plane) for the liveness check.
