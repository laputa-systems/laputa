# Architecture

Native Rust handles SSH protocol and I/O; XSH handles infrastructure policy.
xsh-infra is XSH only. It adds no language syntax, async runtime, daemon or
Rust code, and it keeps no state on the controller or the hosts beyond the
host lock directory while an apply runs.

## Layers

| Layer | Modules | Rule |
|---|---|---|
| Declaration | `model`, `declare`, `check`, `deployment` | Pure. Resources are values; constructors validate and touch nothing. |
| Planning | `graph`, `compare`, `workload` | Pure except `workload.prepare`, which measures local content and reads secret variables. Ordering, merging and comparison are `pure` functions. |
| Facts | `scripts`, `probe`, `fact` | Constant scripts print a hex-encoded `key value` protocol; `probe` parses it into typed facts. Unreadable facts are a case of their own. |
| Effects | `transport`, `observe`, `mutate`, `lock`, `content` | The only modules that reach a host or the local filesystem for a resource. |
| Reconciliation | `engine`, `outcome` | Plan, check and apply across hosts: barriers, bounded concurrency, failure policy, verification. |
| Surfaces | `report`, `doctor`, `app`, `bin/xinfra.xsh` | Rendering, validation of hosts, option parsing. |

Test helpers (`tests/infra/testing.xsh`) are not part of the library and are not installed.

## The transport boundary

Everything that reaches a host is `transport.exec(connection, operation, args)`:
one catalogue operation and positional arguments. A host declares its login
shell as `dialect` (`posix`, the default, or `xsh`), and `scripts.source` is the
only selector: one constant exists per (operation, dialect), and an operation a
dialect does not provide is a typed refusal, never the other dialect's script.

For `posix`, `shell.command` renders

```
/bin/sh -c '<script>' xinfra 'arg1' 'arg2'      (prefixed with doas -n when escalating)
```

`shell.quote` is the only place a value becomes shell source: it single-quotes a
word and refuses NUL. Scripts are constants in `scripts.xsh` and read their
values as `"$1"`; no request value is ever spliced into script text.

For `xsh`, the command string *is* the XSH source. A login shell such as
Laputa's `/usr/bin/xsh-login` executes its `-c` argument as a program, so the
source is sent directly and nothing is wrapped in `sh -c`. `shell.xsh_command`
prepends `let xinfra_args: List[Str] = [...]` to the constant source; each
operand becomes an XSH double-quoted string literal through `shell.xsh_quote`,
which escapes quotes, backslashes, `$`, control bytes and non-ASCII bytes and
refuses NUL. The operand is data: it cannot terminate the literal or change the
program. The round trip is tested with hostile values through the local `xsh`
and through `xsh-login` in the guest run. The `xsh` dialect has no `doas`
wrapper; inventory refuses `privilege = "doas"` with it.

The quoting round trip is tested with hostile values (quotes, newlines, `$()`,
backticks, leading hyphens, empty strings, non-ASCII) through a local `sh -c` and
through the Alpine login shell, and `doctor` repeats it on every host with the
dialect's own renderer. Paths are absolute UTF-8 text with no NUL, empty, `.` or
`..` component; anything else is refused at declaration instead of being
converted.

Remote hosts use the native `ssh` module: one authenticated session per host,
reused for facts, the lock and every mutation. The `local` transport runs the
same command string through the dialect's interpreter (`sh` or `xsh`) and exists
for tests and development only. There is no other production backend and no
external `ssh`, `scp` or `sftp`.

Output is a protocol, not formatted `ls`: free-form text (owners, symlink
targets, error text) is hex encoded by the remote script and decoded by `probe`,
so newlines and odd bytes survive. Absent, unreadable, blocked (a parent is not
a directory) and malformed are different facts.

## Service adapters

`model.ServiceAdapter` is the closed set of service managers. The OpenRC
adapter probes `/etc/init.d`, runlevel membership and `rc-service status`, and
controls enablement with `rc-update` and running state with `rc-service`. The
xinit adapter treats a file under `${XINIT_SERVICE_DIR}` (default
`/usr/lib/xinit/services`) as existence, parses the documented
`xinit status SERVICE` line for `running`, `starting`, `dead`, `down`,
`pending`, `finishing` and `ready`, and controls only the documented verbs:
`start`, `stop`, `restart` and `reload`. It declares no enablement because
xinit has none; a declaration that asks for it is refused before connecting.
Running-state control needs write access to `/run/xinit`: on a POSIX target the
host must run as root or through `doas -n`, and on an `xsh` target as root
because that dialect has no doas wrapper.

The adapter runs through the transport's `xsh` dialect on a stock Laputa
generation, whose login shell `/usr/bin/xsh-login` executes its `-c` argument as
XSH and whose `/bin/sh` is a disabled `xshi` applet. The file, directory,
symlink, argv command, xinit service and lock operations all have XSH sources.
Package, account, OpenRC service and shell-string command resources have none:
declaring one for an `xsh` host is refused by `workload.prepare` before anything
connects, and the transport would refuse it again if it were asked. xinit's
running-state control still needs write access to `/run/xinit`, so an `xsh` host
must use `privilege = "root"` or `plain`.

## Execution certainty

A failed `ssh.exec` is classified once, in `transport.certainty_of`, from the
`certainty` every `SshError` carries: a failure that never reached the host is
`NotSubmitted` (the step did not happen); one that may have is `Interrupted`,
and a signal death or a close without an exit status is `Abnormal`. `mutate`
turns these into `failed`, `partial` or `unknown` step errors. A mutation is
never replayed after a lost connection; the next apply re-observes. A session
that failed is unusable (`transport.usable`), so the lock release uses a fresh
connection.

`SIGINT` or `SIGTERM` aborts the run at a checkpoint. `apply` marks the resource
being reconciled on each host before it launches a barrier, and its unwind
`defer` renders a cancellation report from the states reached so far: that
resource is `unknown`, resources not started are `blocked`, recorded entries are
kept, and the host is failed. The report goes to stderr because stdout belongs
to the requested format and an aborted run never returns a normal report. The
same `defer` releases every lock.

## File safety

Replacing a regular file: `mktemp` creates a private file in the destination
directory; the content streams from stdin (a local file is never loaded); the
staged digest and size are compared with the intended content, which detects a
source that changed during the transfer; mode and owner are set on the staged
file; the optional validator runs on it; `mv -f` promotes it (refusing a
directory destination); the result is re-observed. Any failure before promotion
leaves the live file and removes the staged one, and a cleanup failure is
appended to the primary failure, never replacing it. A no-op rewrites nothing and
leaves the mtime alone.

## Deliberate omissions

- No fact cache, so none to invalidate. The cost is one round trip per
  resource per phase; the benefit is that no read can predate a mutation.
- No saved or approvable plan file. `plan` is a preview; `apply` always
  recomputes from current facts, so a stale approval cannot be applied.
- No retry of a mutation after a lost connection.
- No agent, password, `known_hosts` or certificate trust; no `~/.ssh` reads.
- No PTY, no interactive prompts, no sudo; `doas -n` only.
- No Python, remote Python, `jq`, systemd or hidden bootstrap. Remote XSH is
  the documented Laputa exception: an `xsh` host receives catalogued XSH source
  for `xsh-login -c`, one constant per operation, with operands as escaped
  literals. It is never produced by translating POSIX script text, and every
  other target remains POSIX. See the transport boundary above.
- No service operation xinit does not define. Its adapter uses `xinit status`
  for running and readiness, the scanned service directory for existence, and
  `xinit start`, `stop`, `restart` and `reload` for control. xinit has no
  enable/disable, so `enabled` is refused at declaration. The adapter enum is
  closed with OpenRC and xinit.
- No recursive deletion, no UID/GID change, no user-data removal.
- No plugin framework, no hidden global host context, no source-line hashing.
