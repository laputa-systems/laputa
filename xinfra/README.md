# xsh-infra

A small configuration-management tool written in [XSH](https://github.com/laputa-systems/xsh),
inspired by pyinfra. It reconciles Alpine/Laputa-style hosts over XSH's native
SSH client: no Python, no daemon, no external `ssh`. A POSIX target receives
constant `/bin/sh` scripts. A Laputa target, whose login shell executes its `-c`
argument as XSH, receives catalogued XSH source instead (the documented
per-target exception).

```sh
xinfra doctor INVENTORY                 # validate hosts, keys, shell, tools, authority
xinfra plan   INVENTORY DEPLOYMENT      # read facts, report what apply would change
xinfra check  INVENTORY DEPLOYMENT      # report compliance; exit 1 on drift
xinfra apply  INVENTORY DEPLOYMENT      # reconcile, then verify each change
xinfra unlock INVENTORY HOST [--token T]
```

Declare resources in an ordinary XSH module, list hosts in TOML, and run:

```sh
xsh bin/xinfra.xsh plan .work/fixtures/inventory.toml examples/alpine-web/deploy.xsh
```

Resources: directories, regular files (local source, text or rendered
template, optional validator, atomic replacement), symlinks, Alpine packages,
groups and users, commands with an explicit idempotence condition, and OpenRC
or Laputa xinit services with change-triggered reload or restart. The xinit
adapter uses only xinit's documented status and control verbs; it has no
enable or disable. Reports are text, JSON or
JSON Lines.

- [Usage](docs/USAGE.md): inventory, deployment programs, every resource, the
  commands, exit statuses and report formats.
- [Operations](docs/OPERATIONS.md): trust setup, secrets, doas, locks, failure
  outcomes and recovery.
- [Architecture](docs/ARCHITECTURE.md): layers, the transport boundary, the file
  safety model and what was left out on purpose.
- [Capability and platform matrix](docs/MATRIX.md).
- [Testing](docs/TESTING.md) and the [pyinfra comparison](docs/PYINFRA.md).
- [Requirements on XSH](docs/XSH-API.md): the XSH behavior this relies on.

Requirements: a qualified `xsh` with the native `ssh` module and `xsht` for the
tests. POSIX targets need an SSH server that runs commands, a POSIX `sh`, and
BusyBox or GNU `stat`, `sha256sum`, `od`, `mktemp` and friends. Laputa targets
need `/usr/bin/xsh-login` as the login shell and the XSH runtime; their
`/bin/sh` is never used. See the matrix. Install the runtime with
`xsh packaging/install.xsh PREFIX`.
