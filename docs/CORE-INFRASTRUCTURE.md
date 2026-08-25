# Laputa Core Infrastructure Architecture Contract

This document is the durable architecture contract for the Laputa core-infrastructure maturation. It defines the intended end state; it does not describe the legacy implementation as a compatible interface.

## Scope and constraints

The only supported build and system target is `aarch64-linux-musl`. Package builds, package proofs, root composition, and disk-image creation run in native `linux/arm64` Docker containers. Laputa's QEMU proof runs on a macOS aarch64 host with `qemu-system-aarch64` and HVF.

The new architecture must not introduce or retain new x86-64, amd64, native-cross, binfmt, or emulated package-build paths. Existing x86-64 package definitions may remain, but the planner must clearly reject every non-aarch64 target. Do not run x86-64 tests merely to preserve legacy behavior.

The reference system is exclusively `qemu-dwl-foot`. Its acceptance condition is a real QEMU boot into dwl with a real foot terminal and deterministic injected keyboard input. Browsers, browser packages, real hardware, installers, audio, Tailscale, Mesa feature expansion, and general-purpose hardware profiles are outside this scope.

Preserve the existing remote package tarball and index format where practical; optional metadata extension is permitted. Internal world-cache and PM CLI compatibility are not required. Delete legacy world state rather than implementing migration for `.world/state.json`.

Build and publication are separate operations. Publication credentials come only from `LAPUTA_TOKEN`; they must never be stored in roots or PM state. Package build recipes must not rely on ambient `/bin/sh`, `/usr/bin/sh`, `SHELL`, or shell command strings. Host-side Docker and QEMU orchestration must use structured `process.command_argv`.

Do not add a general plugin framework, derivation language, daemon, database, garbage collector, user profile system, live-root activation protocol, or distributed builder. New XSH modules with exports require module documentation and documentation on every exported declaration. Static checks use the checked-out local `xsht`; behavioral tests use the pinned published Linux XSH binaries. Repository publication must fail closed. Semantic plan and artifact identities use canonical deterministic encodings: timestamps, absolute host paths, concurrency levels, credentials, and cache locations must not affect them.

## Ownership boundary

```text
packages/
    package recipes
    validated package catalog
    dependency graph
    BuildPlan
    immutable package artifacts
    package proofs
    root composition
    repository snapshots and publication

laputa/
    SystemProfile
    Docker execution adapter
    generation request
    ext4/GPT image construction
    QEMU configuration and lifecycle
    guest proof program
    QMP input and screenshot proof
```

`laputa` may import package-manager modules while executing inside the Linux container. It must not reimplement dependency resolution or list transitive packages manually.

`packages` must know nothing about QEMU, dwl sessions, disk partitioning, Cocoa displays, or macOS.

## Canonical pipeline

```text
Package modules
    ↓
Validated Catalog
    ↓
Typed dependency graph
    ↓
Deterministic BuildPlan
    ↓
Immutable proved package artifacts
    ↓
Typed SystemProfile
    ↓
Immutable root generation
    ↓
Atomic ext4/GPT image
    ↓
QEMU boot proof
```

Every arrow is an explicit checked boundary.

## Principal invariants

1. **One package model:** Recipe metadata is decoded and validated once. Pure planning code never reads arbitrary dynamic module exports.
2. **One graph implementation:** Runtime closure, build closure, topological ordering, rebuild propagation, and system closure all derive from the same typed edge set.
3. **One plan:** Build execution and publication consume a saved plan and may not repeat resolution against mutable local or remote state.
4. **Exact identities:** Editing a semantic build input changes the affected artifact key. Editing proof code changes the proof key without necessarily changing the artifact key.
5. **No mutable world root:** Every locally built package receives a fresh isolated root composed from exact dependency artifacts.
6. **Atomic artifact publication:** An interrupted package build never leaves a valid-looking final artifact directory.
7. **Atomic system composition:** An interrupted generation or image build cannot alter the last complete generation or image.
8. **Runtime purity:** Build-host and target-build dependencies never enter a final system generation merely because they were required to compile a runtime package.
9. **No package-list duplication:** `qemu-dwl-foot` package intent appears once in its profile. Dockerfiles and proof scripts do not carry independent transitive package lists.
10. **No ambiguous CLI:** Commands never infer whether an argument is a package name or package directory by inspecting the filesystem.
11. **No build-and-upload command:** Upload is only legal from a complete, verified plan and artifact set.
12. **No silent overwrite:** Publishing an existing package tuple with different bytes fails.
13. **Reference proof:** A clean macOS Apple Silicon checkout can use Docker to produce an aarch64 image and QEMU to prove dwl + foot input end to end.

## Final public CLI

### Package manager

```text
pm repo check [--repo PATH]
pm repo plan [--repo PATH] (--all | --root PACKAGE...) \
  --target aarch64-linux-musl \
  --output PLAN
pm repo show PLAN
pm repo build PLAN --store STORE [-j N|--jobs N]
pm repo publish PLAN --store STORE
pm repo checksum [--repo PATH] PACKAGE...
pm repo update-checksums [--repo PATH] PACKAGE...
pm repo source-audit [--repo PATH] PACKAGE...

pm root compose PLAN \
  --store STORE \
  --runtime-root PACKAGE... \
  --output GENERATION

pm root inspect GENERATION
pm store verify --store STORE
```

The public PM must remove `world-plan`, `build-install`, `build-set`, `build-set-deps`, `build-upload-set`, `upload-set`, `upload-repo-export`, `refresh-index`, `auth`, and `help-ext`. It must not retain heuristic aliases.

The PM does not promise online mutation of a live `/` in this phase. Immutable generation composition is the supported system-installation primitive. Reusable read-only package database inspection may remain, but a misleadingly transactional `pm install` or `pm remove` must not be exposed until real activation semantics exist.

### Laputa

```text
laputa plan qemu-dwl-foot
laputa build qemu-dwl-foot [-j N|--jobs N]
laputa test qemu-dwl-foot
laputa boot qemu-dwl-foot
laputa clean qemu-dwl-foot
```

`plan` generates and prints the exact package and generation plans without building. `build` resolves, builds or imports exact artifacts, composes the root generation, and creates the disk image. `test` ensures a current image exists, boots it noninteractively, injects input through QMP, captures a screenshot, and validates console markers. `boot` opens the Cocoa QEMU display and launches the normal dwl + foot session. `clean` removes only `target/laputa/qemu-dwl-foot`; it must not destroy the immutable artifact-store volume.

The profile and command determine behavior; the CLI must not expose dozens of environment-controlled proof modes.

## Final file structure

```text
packages/
├── pm.xsh
├── pm/
│   ├── cli.xsh
│   ├── types.xsh
│   ├── recipe.xsh
│   ├── catalog.xsh
│   ├── policy.xsh
│   ├── graph.xsh
│   ├── fingerprint.xsh
│   ├── plan.xsh
│   ├── plan_json.xsh
│   ├── store.xsh
│   ├── root.xsh
│   ├── execute.xsh
│   ├── build.xsh
│   ├── proof.xsh
│   ├── sources.xsh
│   ├── remote.xsh
│   ├── repo.xsh
│   ├── generation.xsh
│   ├── elfdeps.xsh
│   ├── env.xsh
│   ├── make.xsh
│   ├── meson.xsh
│   ├── configure.xsh
│   ├── target.xsh
│   └── util.xsh
├── tests/xsh/
│   ├── pm_recipe.xsh
│   ├── pm_graph.xsh
│   ├── pm_plan.xsh
│   ├── pm_store.xsh
│   ├── pm_root.xsh
│   ├── pm_execute.xsh
│   ├── pm_repo.xsh
│   ├── pm_cli.xsh
│   └── fixtures/
├── PM.md
└── LAPUTA.md

laputa/
├── laputa.xsh
├── laputa/
│   ├── cli.xsh
│   ├── types.xsh
│   ├── profile.xsh
│   ├── docker.xsh
│   ├── build.xsh
│   ├── image.xsh
│   ├── qemu.xsh
│   └── proof.xsh
├── profiles/
│   └── qemu-dwl-foot.xsh
├── guest/
│   └── qemu-dwl-foot-proof.xsh
├── boot/
│   └── qmp-proof.py
├── tests/xsh/
│   ├── profile.xsh
│   ├── docker.xsh
│   ├── image.xsh
│   ├── qemu.xsh
│   └── fixtures/
├── docs/
│   ├── CORE-INFRASTRUCTURE.md
│   ├── DEVELOPMENT.md
│   └── QEMU.md
└── Makefile
```

When migration is complete, delete `packages/pm/world.xsh`, `packages/pm/buildroot.xsh`, and `packages/pm/extensions.xsh`, after removing every import. `packages/pm/install.xsh` may also be deleted after its reusable manifest, metadata, and root-composition logic has moved to focused modules.

The final root `Makefile` contains only thin compatibility aliases. It does not encode package sets, Docker volume topology, world resolution, or QEMU mode policy.

## Initial implementation baseline

This non-normative record captures the local repository commits before implementation of this architecture began. It does not constrain later commits or alter the normative contract above.

```text
xsh:      a2f3fd4f12a3fd99e9ccbf6787d7bc5fc72dcda4
packages: ec0838dbbdc1b20a3eada75d628cb0455e318b6b
laputa:   a6d9a1e2525ab5c271c764170871b0dbe0ef6eeb
xinit:    a12a87d3b40d9cfad80e3aa77458f81568494113
```
