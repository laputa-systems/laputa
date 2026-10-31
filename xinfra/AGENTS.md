# xinfra

xinfra is a configuration-management tool for Alpine hosts, written in XSH.
[README](README.md) covers install and use; this file routes developer work.

## Commands

| Command | Purpose |
|---|---|
| `make check` | Static checks over the source tree. |
| `make test` | Unit and golden tests. |
| `make integration` | Remote scenarios on the Lima fixtures. |
| `make differential` | Compare against pyinfra 3.10.0. |
| `make package` | Build the source tarball under `.work/dist`. |
| `make install PREFIX=DIR` | Build, unpack, and install under `DIR`. |
| `make fixtures` / `make verify` / `make down` | Start, probe, or remove the `xinfra-*` guests. |

The Makefile uses the release pair under `XSH_ROOT` (default `../../xsh`); set
`XSH` or `XSHT` to run other binaries. Fixtures and scratch live under `.work`;
keep it excluded through `.git/info/exclude`. `dev/pins.env` records the
qualified XSH pin.

## Layout

- `bin/xinfra.xsh` is the CLI entry point.
- `lib/xinfra/` holds the model, validation, planner, driver, and resources.
- `tests/` is the XSH unit suite.
- `dev/` holds fixtures, integration cases, differential, performance, and packaging.
- `examples/alpine-web/` is a runnable deployment.

## Invariants

- A deployment declares resources; loading and planning never mutate a host.
- All remote I/O goes through `lib/xinfra/transport.xsh` with `/bin/sh -c`,
  `LC_ALL=C`, a fixed `PATH`, and `shlex` quoting.
- Host trust is a pinned `SHA256:` Ed25519 host key and an unencrypted Ed25519
  user key. There is no `known_hosts`, agent, password, PTY, or SFTP path.
- A file stages in the destination parent, validates there, and is promoted
  only after verification. The live object stays until promotion.
- Secrets are env or file references resolved at apply. They never enter argv,
  the remote environment, plans, reports, or packages.
- `apply` takes one lock per host. A submitted mutation is never retried, and
  an unknown result is not success.
- The guest and the package contain no Python, pyinfra, or agent. pyinfra is a
  test oracle under `.work` only.

## Docs

- [Resources](docs/resources.md) — resource fields and semantics.
- [Operations](docs/operations.md) — plan/apply, failures, locks, saved plans.
- [Security](docs/security.md) — host trust, secrets, privilege.
- [Platform](docs/platform.md) — supported systems and architecture.
- [Compatibility](docs/compatibility.md) — pyinfra comparison.
- [Performance](docs/performance.md) — measured costs.
- [Qualification](docs/qualification.md) — acceptance record and limits.
- [TODO](TODO.md) — known gaps and priorities.
