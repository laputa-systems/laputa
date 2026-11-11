# Usage

Run from a checkout with `xsh bin/xinfra.xsh COMMAND ...`, or install with
`xsh packaging/install.xsh PREFIX` and run `PREFIX/bin/xinfra`. The examples
below write `xinfra`.

## Inventory

TOML. Keys in `[defaults]` apply to every host; a host overrides them. Unknown
fields are errors.

```toml
[defaults]
user = "deploy"
privilege = "doas"            # plain | root | doas
key = "keys/id_ed25519"       # unencrypted Ed25519 OpenSSH key; relative to this file
timeout_ms = 10000            # connect and ordinary command timeout
transfer_timeout_ms = 600000  # file transfers

[groups.web.vars]
tier = "web"

[hosts.web-1]
address = "10.0.0.11"
port = 22
host_key = "SHA256:..."       # required pin; no known_hosts, no trust on first use
groups = ["web"]
escalate_reads = true         # default: true when privilege = "doas"

[hosts.web-1.vars]
title = "front door"
```

`transport = "local"` runs the same scripts through a local `/bin/sh` for
development and tests; it needs no address, key or pin. Host variables merge
defaults, then groups in listed order, then the host.

`--limit NAME` (repeatable) selects hosts or groups. A name matching nothing is
an error.

## Deployment programs

An ordinary XSH module that exports `resources`:

```xsh
##! My deployment.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [
    declare.directory(id: "data", at: "/srv/data", mode: 0o750, parents: true)?,
    declare.file(id: "motd", at: "/etc/motd", text: "hello\n", needs: ["data"])?,
  ]
}
```

The effect clause is `[fs, error]` exactly. The contract is checked when the
module loads, so a deployment that runs processes, reads the environment or
touches the network is refused. Declaring builds values and mutates nothing.
Deployments are trusted operator code: loading one runs its module
initializers, and `plan` is not a sandbox for arbitrary XSH. Relative template
paths resolve against the working directory.

Each resource has a stable `id`, optional `needs: [ids]`, and a kind. Order is
declaration order, adjusted so every resource follows what it needs. Duplicate
ids, unknown ids, self-dependencies and cycles are refused before anything
connects. Hosts that declare shared ids in a different relative order are
refused.

## Resources

All constructors are in `infra.declare` and validate their arguments where they
are called.

| Constructor | Declares |
|---|---|
| `directory(id, at, presence, owner, group_name, mode, parents, needs)` | A directory. `Absent` removes only an empty directory. |
| `file(id, at, presence, text / data / source / secret_env / template_file+template_json, owner, group_name, mode, validate, sensitive, needs)` | A regular file with exactly one content source. |
| `symlink(id, at, target, presence, replace, needs)` | A symlink. An existing link is replaced only with `replace: true`; a file or directory is never replaced. |
| `package(id, name, presence, version, needs)` | An Alpine package through `apk`. `version` is `1.2-r0` or a bound like `>=1.2-r0`, compared in apk's ordering. |
| `package_index(id, needs)` | An explicit `apk update`, run at apply only and reported on its own. |
| `group_account(id, name, presence, gid, needs)` | A group. A different gid is a conflict, never changed. |
| `user_account(id, name, presence, uid, primary_group, groups, home, shell, system_account, needs)` | A user. `groups` are memberships that must hold; extras are left alone. A different uid is a conflict. Removal keeps the home directory and data. |
| `command(id, argv / shell, creates / skip_if / only_if / run_on / always, stdin_env, accept, timeout_seconds, needs)` | A command with exactly one condition (below). |
| `service(id, name, enabled, running, runlevel, reload_on, restart_on, needs)` | An OpenRC service. Triggers imply dependencies. |

Command conditions: `creates: "/path"` (skip when it exists), `skip_if: [argv]`
or `skip_if_shell: "text"` (skip when the read-only guard exits 0),
`only_if` / `only_if_shell` (run when it exits 0), `run_on: [ids]` (run only
after a listed resource changed), or `always: true`. A command with none is
refused: it would not be idempotent. Guards run during `plan` and `check`, so
they must be read-only. A guard that cannot run (exit 126 or above) is an
uncertain fact, not a reason to run the command.

Several changed triggers coalesce: a service with `reload_on: [a, b]` is
reloaded once per apply however many of `a` and `b` changed, and a restart
trigger supersedes a reload. A stopped service is not reloaded.

File content: `text` and `data` are held in memory; `source: p"..."` streams
from a local file; `secret_env: "NAME"` reads a controller environment variable
that is redacted everywhere; `template_file` renders a Go text/template file
against the JSON object `template_json` when the content is measured or sent.
`validate: ["tool", "-t", "{}"]` runs on the staged file with `{}` replaced by
its path before the live file is replaced; a failure leaves the live file.

## Commands

| Command | Reads | Changes | Locks | Exit |
|---|---|---|---|---|
| `doctor INVENTORY` | connection, shell, tools, authority, lock | nothing | no | 0 or 3 |
| `plan INVENTORY DEPLOYMENT` | facts | nothing | no | 0, or 3 on failure |
| `check INVENTORY DEPLOYMENT` | facts | nothing | no | 0 compliant, 1 drift, 3 failure |
| `apply INVENTORY DEPLOYMENT` | facts, again before each change | yes, then verifies | yes | 0, or 3 |
| `unlock INVENTORY HOST [--token T]` | the lock holder | releases with the right token | | 0, or 2 |

Exit 2 means invalid input found before any host was touched (inventory,
deployment, dependency graph, unreadable local source, unset secret, bad
option). Exit 3 means a host failed or an outcome needs attention: failed,
partial, unknown, a conflict, or a fact that could not be read.

Options: `--limit NAME`, `--jobs N` (1..64, default 4, bounds concurrent hosts
and connections work), `--format text|json|jsonl`, `--verbose`,
`--failure host|abort|continue` (apply), `--lock-path PATH` (default
`/run/xinfra.lock`; `{host}` is replaced by the host name).

## Plan, check and apply

Facts are read fresh for every resource; nothing is cached, so no observation
outlives a mutation. Apply re-observes before each change, compares, acts on
what differs, then re-observes and compares again. A resource whose fact could
not be read is `uncertain`, never `unchanged`. A plan marks a resource
`(conditional)` when something it needs is planned to change, because the host
may differ by the time it runs.

Operations form barriers across hosts: operation N finishes or fails on every
host that declares it before N+1 starts, and hosts inside an operation run
concurrently up to `--jobs`. By default (`--failure host`) a failed host gets no
further mutations and its remaining resources are `blocked`; other hosts
finish. `--failure continue` blocks only resources that depend on the failure.
`--failure abort` starts no new operation on any host after a failure. A
barrier does not mean success: the overall result fails whenever a host failed.

## Reports

Outcomes: `unchanged`, `changed` (with `verified`), `skipped` (a command's
condition said no), `blocked` (a dependency or earlier failure), `failed`,
`partial` (earlier steps of the resource took effect), `unknown` (the request
may have reached the host). Plan and check use `satisfied`, `drift` (with the
`act` and field changes), `conflict`, `uncertain` and `not-evaluated`.

`--format json` prints one document; `--format jsonl` prints one object per
entry or host failure and a final summary object with the exit status. Every
entry carries host, resource id, kind, status, phase and cause. Text from hosts
is sanitized of terminal control sequences; secret values are replaced by
`***`; sensitive file digests are shown as `(redacted)`.

If `SIGINT` or `SIGTERM` aborts an `apply`, the requested format does not apply:
the controller writes a text outcome report to stderr, marks the active resource
`unknown` and unstarted resources `blocked`, releases the lock and exits 3.
Re-run to converge; see [Operations](OPERATIONS.md#cancellation).
