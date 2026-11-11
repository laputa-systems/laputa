# Operations

## Trust setup

- Pin each host's key: `host_key = "SHA256:..."` is mandatory and is the only
  trust mechanism. Get it from a trusted channel, for example
  `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` run on the host. A changed
  key fails that host at `connect` before authentication or mutation.
- Authentication is an unencrypted Ed25519 OpenSSH key file named by `key`.
  Keep it mode 0600 and out of repositories. Encrypted keys, agents, passwords
  and certificates are not supported by the native client yet.
- xsh-infra never reads `~/.ssh`, writes `known_hosts`, or invokes `ssh`.

## Authority

`privilege` says how mutations run: `plain` as the login user, `root` as a
login that already is root (`doctor` checks uid 0), or `doas` through
`doas -n`. The doas policy is yours: xsh-infra never edits doas or SSH access.
A minimal rule: `permit nopass deploy`. Escalation failure shows as a failed
host (`lock` phase) before any mutation. With `privilege = "doas"` reads are
escalated too, so plans see root-only paths; set `escalate_reads = false` to
read as the login user and get `uncertain` for what it cannot read.

## Secrets

- `secret_env` file content and `stdin_env` command input come from controller
  environment variables, are streamed on stdin and never placed in argv, plans,
  diffs, errors or JSON. Secrets shorter than 4 bytes are refused because they
  cannot be redacted reliably.
- Every message that came from a host is scanned for known secret values before
  it is stored. A command that prints a secret in some transformed form (for
  example base64) is not caught.
- Staging files are created mode 0600 by `mktemp` under umask 077, in the
  destination directory, and take their final mode only just before the rename.
- Do not put secrets in inventory vars or in deployment text: those appear in
  plans.

## The host lock

`apply` takes `/run/xinfra.lock` (a directory made with `mkdir`) on each host
before its first mutation and releases it at the end, on failure, and on
`SIGINT`/`SIGTERM`. The lock holds an ownership token and a holder description.
A second apply sees `another apply holds ...` and fails that host. Plan, check
and doctor take no lock.

A controller killed with `SIGKILL` or a power loss leaves the lock. xsh-infra
never steals a lock because it looks old or its holder looks gone. Inspect and
release it yourself:

```sh
xinfra unlock INVENTORY HOST                 # shows the holder, starting with the token
xinfra unlock INVENTORY HOST --token TOKEN   # releases only if the token matches
```

If a lock cannot be released at the end of a run (for example the connection
died), the host is reported failed in phase `release` with the token and the
command to run.

## Cancellation

`SIGINT` or `SIGTERM` to the controller starts shutdown at the next checkpoint.
An in-flight remote request is interrupted and treated as uncertain; no request
is replayed. The controller then releases the host lock and writes a text
outcome report to stderr: the resource being reconciled is `unknown`, resources
that had not started are `blocked`, and anything that completed earlier keeps
its recorded outcome. The process exits 3. The requested `--format` applies to a
completed run; the cancellation diagnostic is always text and stdout carries no
report. A second signal escalates and may skip cleanup, as XSH documents.

Re-run `check` or `apply` afterwards. Every action is recomputed from fresh
facts, so an interrupted request that did reach the host is observed as
`unchanged` or repaired. A killed streamed file leaves the destination
untouched and may leave a private `.xinfra.XXXXXX` file that you remove by hand.
An OpenRC start interrupted inside `start_pre` can leave OpenRC's `starting`
state; stop the service before re-running. Other in-flight reloads leave the
running service intact.

## Failure outcomes and recovery

- `failed`: the step did not take effect. Fix the cause and apply again.
- `partial`: earlier steps of this resource took effect (for example a user was
  created and joining a group failed). Applying again converges, because every
  step is recomputed from fresh facts.
- `unknown`: the request may have reached the host and the connection or
  command timed out or died. xsh-infra never replays it. Re-run `check`; a plan
  or apply re-observes and acts only on what still differs. A file transfer that
  dies leaves its destination untouched and may leave a private
  `.xinfra.XXXXXX` file in the destination directory; remove it by hand.
- `blocked`: a dependency or an earlier failure on the host stopped this
  resource; nothing was done.
- Atomic visibility of a file is not whole-deployment atomicity, crash
  durability or rollback. Package scripts, databases and service side effects
  are not rolled back.

## Trusted-directory model

Staging and promotion use a private temporary file in the destination
directory and a same-directory `mv -f`; the promote step refuses a directory or
a link to one at the destination. Shell scripts cannot confine path resolution:
a local attacker who can write to the destination directory or race symlinks in
it can interfere. Manage directories that only trusted users can write.
