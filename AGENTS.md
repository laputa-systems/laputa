# Laputa Agent Guide

Laputa is a Linux distribution built and managed in XSH. This monorepo owns
its package manager, recipes, init, installer, system tooling, and mirror.

## Commands

The root `Makefile` is the entry point; `ARCH` defaults to the host.

- Bootstrap: `make host-xsh` (Linux), `make fetch`, `make seed`.
- Packages: `make plan`, `make build [PKGS=… | STOP=pre-cmake]`.
- Mirror and roots: `make mirror`, `make publish`, `make root PKGS="…"`.
- Check: `make check`; focused tests: `$XSHT test tests/pm/pm_plan.xsh`.
- Suites: `make test-pm`, `make test-system`, `make test-xinit`, `make test-linux`.
- Mirror checks: `make mirror-build`, `make mirror-test`.

Host-tool setup, the full target reference, and cleanup are in
[development](docs/DEVELOPMENT.md).

## Hard invariants

- Read `../xsh/AGENTS.md` before editing XSH or writing `.xsh` here.
- Use typed imports, structured argv, explicit effects, and `?` at error boundaries.
- Public exports need domain-qualified names where the global symbol table could collide.
- `pm/recipe.xsh` is the sole dynamic recipe boundary; preserve PM module ownership.
- Package builds must not rely on `/bin/sh`, `/usr/bin/sh`, or `SHELL`, including generated rules.
- Kernel userspace consumers build-depend on `linux-headers`, never `linux`.
- Document regeneration beside generated package inputs; expose XSH applets only as needed.
- Use the typed profile CLI; stage container builds locally and publish complete outputs atomically.
- `system/qemu.xsh` owns host QEMU mechanics; profiles hold system intent.
- Fix required Asterinas syscalls in the pinned fork with kernel tests, without userspace workarounds or skips.
- xinit must own process groups, use auditable signals, and avoid order-dependent global state.
- xinit test-only switches must not change production behavior.
- Service schema changes update every installed/generated service and run `xsh xinit/xinit.xsh -- check PATH`.

## Topic owners

| Topic | Documentation |
|---|---|
| Host setup, bootstrap, make targets, derived state | [Development](docs/DEVELOPMENT.md) |
| Layout, ownership, identities, image boundaries | [Core infrastructure](docs/CORE-INFRASTRUCTURE.md) |
| Recipes, source inputs, plans, store, roots, publication | [Package manager](docs/PM.md) |
| Typed Makefile-style build graphs | [Make task graphs](docs/MAKE.md) |
| Open work | [TODO](TODO.md) |
| Focused tests and wider verification | [Testing](docs/TESTING.md) |
| Native Docker/QEMU profile and graphical proof | [QEMU](docs/QEMU.md) |
| Installer images, install policy, QEMU harness | [Installer](docs/INSTALLER.md) |
| Pinned Asterinas/Firecracker build, test, serial shell | [Asterinas](docs/ASTERINAS.md) |
| Root bundle, trust policy, signed releases | [Certificate trust](docs/CERTIFICATE-TRUST.md) |
| Mirror host/Cloudflare operations and rollback | [Mirror deployment](docs/MIRROR-DEPLOYMENT.md) |
| Mirror invocation, publishing, client settings | [Mirror usage](mirror/README.md) |
| xinit command line | [xinit](xinit/README.md) |
| PID 1, inittab, service fields and commands | [xinit contract](xinit/docs/INIT.md) |
| Scanner, readiness, status, control plane | [xinit supervision](xinit/docs/SUPERVISION.md) |
| WebAuthn API used by the mirror | [WebAuthn](mirror/webauthn-minimal/README.md) |
| Mesa generator replacement and regeneration | [Mesa generated inputs](packages/mesa/files/generated/README.md) |

Read both xinit docs before changing its inittab engine, scanner, readiness,
or status handling. Fixtures under `tests/*/fixtures/` are inputs, not tests.
