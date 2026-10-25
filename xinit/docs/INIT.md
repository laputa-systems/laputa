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
`getpid() == 1`. Test-only `XINIT_TEST_*` and `XSH_INIT_TEST_*` switches are
read in `xinit.xsh`.

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

The fields read are defined in `service_from_record` in `xinit.xsh`. Other
fields are not rejected and have no effect.

| Field | Meaning |
|---|---|
| `name`, `command` | Service name and spawn command. |
| `kind` | `longrun` (default), `oneshot`, or `scripted`. |
| `targets` | Targets selected by `boot [TARGET]`; default target is `boot`. |
| `dependencies` | `need`, `uses`, `after`, `before`. |
| `restart` | `mode`: `always`, `on_failure`, `never`; default `on_failure` for `longrun`, `never` otherwise. `delay_ms`, `max_delay_ms`, `stable_after_ms`. |
| `readiness` | `"notify"` or the default. |
| `ready_timeout_ms`, `stop_timeout_ms` | Defaults 5000 and 200. |
| `logging` | `"append"` (default) or `"off"`. |
| `log` | `{mode, max_size, keep}`; ignored when `logging` is set. |
| `resources` | `{cpu_max: N}`. |

A module may also export lifecycle procs. `start()` and `stop()` replace the
default spawn and stop, `reload()` replaces the `SIGHUP`, `ready()` gates
dependents, `status()` appends text to the `status` line, and `finish()` runs after the
instance exits, on a clean stop or a crash, while the unit reports
`finishing`. Signatures are in `ServiceFile` in `xinit.xsh`.

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

### Readiness

By default a longrun is ready once spawned, or, if it exports `ready()`, when
that returns true within `ready_timeout_ms`. With `readiness: "notify"` the
scanner passes a pipe whose fd number is in `NOTIFY_FD`; the unit is `starting`
until the service writes any byte to it. On timeout the unit becomes `running`
with `ready` false. `status` and `list` report readiness.

### Stop and reload

Without a `stop()` hook, stop sends `TERM` to the saved process group, then
`KILL` after `stop_timeout_ms`. `reload` runs `reload()` if exported, otherwise
sends `SIGHUP` to the saved process group; it does not change state.

### Logs

Append logging is owned by `xinit`: stdout and stderr go as raw combined bytes
to `${XINIT_LOG_ROOT}/SERVICE/current` (directory `0755`, file `0600`). If the
file cannot be created or opened, start fails. `logging: "off"` disables
capture and shows as `log=none` in status.

`current` rotates to `current.1` and shifts older copies up to
`current.<keep>` when it reaches `max_size` bytes; defaults are 1 MiB and 3.
`max_size: 0` disables rotation. Rotation runs before each start and, under a
scanner, each pass by copy-truncate, so a write between copy and truncate may
be lost. There is no compression or timestamping.

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
