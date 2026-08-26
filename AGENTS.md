# Laputa Agent Guide

Laputa owns the typed `qemu-dwl-foot` integration profile, its native
`linux/arm64` Docker adapter, generated disk images, and QEMU proof harness.
Package definitions and PM implementation belong to the sibling `packages`
checkout. Installer tooling is a separate product and must remain isolated.

## Core workflow

Use the typed CLI, never a handwritten package closure or mutable world root:

```bash
"$XSH_HOST" laputa.xsh -- plan qemu-dwl-foot
"$XSH_HOST" laputa.xsh -- build qemu-dwl-foot --jobs 4
"$XSH_HOST" laputa.xsh -- test qemu-dwl-foot
"$XSH_HOST" laputa.xsh -- boot qemu-dwl-foot
"$XSH_HOST" laputa.xsh -- clean qemu-dwl-foot
```

The Docker build adapter must use the checked-out package graph mounted at
`/src/packages`, native `linux/arm64`, and the named artifact/source volumes.
Build staging belongs on the container's Linux filesystem; copy only complete,
atomic final outputs to the host mount. Do not remove an existing named volume
without an explicit request.

## Boundaries

- `laputa/`: profile loading, Docker adapter, generation/image construction,
  QEMU/QMP supervision, and proof.
- `profiles/`: typed profile data only.
- `guest/`: generated-profile guest proof payload only.
- `packages/`: package recipes, BuildPlan, artifact store, root composition,
  repository snapshots, and PM CLI.
- installer scripts: installer-specific entrypoints only; do not route core
  profile work through them.

## XSH and verification

Read the sibling XSH guide before changing `.xsh` files. Use typed module
imports, structured process argv, explicit effects, and `?` at error
boundaries. Public module exports share a global runtime symbol table, so use
domain-qualified names where modules could collide.

Start with the narrowest proof: `xsht check --strict` for changed modules, then
their focused tests, then the Docker profile build, and finally QEMU. Do not
run formatters, linters, pre-commit hooks, release XSH builds, or CI workflows;
do not push. Record runner limitations precisely instead of weakening a typed
or atomic contract.

See `docs/DEVELOPMENT.md` for exact development commands and `docs/QEMU.md`
for QEMU proof outputs and markers.
