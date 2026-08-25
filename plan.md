# Laputa Core Infrastructure Maturation Implementation Plan

> **For agentic workers:** Execute this plan continuously, task by task, using test-driven development and frequent commits. Do not stop after producing another plan or partial scaffolding. Continue until the final QEMU acceptance test passes and the obsolete paths are removed.

**Goal:** Replace Laputa’s procedural world builder, mutable shared package roots, ambiguous PM CLI, and hand-assembled desktop image with a typed deterministic build plan, immutable proved artifact store, transactional root generations, and one canonical `qemu-dwl-foot` system profile.

**Architecture:** `packages` owns package metadata, graph resolution, exact build plans, immutable package artifacts, root composition, and repository publication. `laputa` owns system profiles, Docker orchestration, disk-image construction, QEMU execution, and system-level proofs. A checked and digest-verified `BuildPlan` is the explicit boundary between resolution and execution.

**Tech Stack:** XSH only for new PM, planning, orchestration, image, and proof logic; existing Python QMP helper may remain. Docker runs native `linux/arm64` containers on the macOS Apple Silicon host. QEMU runs `qemu-system-aarch64` with HVF on macOS. Do not add Rust, shell scripts, databases, third-party language runtimes, or new package dependencies.

**Spec:** Materialize the Architecture Contract in this plan at:

```text
~/d/laputa-systems/laputa/docs/CORE-INFRASTRUCTURE.md
```

before substantial implementation begins.

---

## 1. Working Directories

The repositories are already cloned under:

```text
~/d/laputa-systems/xsh
~/d/laputa-systems/packages
~/d/laputa-systems/laputa
~/d/laputa-systems/xinit
```

Use the existing repositories. Do not clone replacements elsewhere.

Before changing anything:

```bash
cd ~/d/laputa-systems

git -C xsh status --short
git -C packages status --short
git -C laputa status --short
git -C xinit status --short

git -C xsh rev-parse HEAD
git -C packages rev-parse HEAD
git -C laputa rev-parse HEAD
git -C xinit rev-parse HEAD
```

Do not reset, discard, overwrite, or stash user changes.

If `packages` or `laputa` contains unrelated uncommitted changes, preserve them by creating worktrees from the current checked-out commits:

```bash
git -C packages worktree add ../packages-pm-refactor -b refactor/typed-pm
git -C laputa worktree add ../laputa-core-refactor -b refactor/core-infrastructure
```

Otherwise work directly in the existing checkouts on new branches:

```bash
git -C packages switch -c refactor/typed-pm
git -C laputa switch -c refactor/core-infrastructure
```

Do not modify `xsh` or `xinit` unless an actual correctness bug makes the requested architecture impossible. In particular, do not turn this project into another XSH language-development effort.

Do not push any branch.

---

## 2. Global Constraints

These apply to every task.

* The only supported build and system target in the new architecture is `aarch64-linux-musl`.
* All package builds, proofs, root composition, and disk-image creation run in native `linux/arm64` Docker containers.
* Do not run or maintain new x86-64, amd64, native-cross, binfmt, or emulated package-build paths.
* Do not run x86-64 tests merely to preserve legacy behavior.
* Existing x86-64 package definitions may remain in the repository, but the new planner must reject non-aarch64 targets clearly.
* QEMU runs on the macOS aarch64 host with `qemu-system-aarch64` and HVF.
* Browsers, browser packages, real hardware, installers, audio, Tailscale, Mesa feature expansion, and general-purpose hardware profiles are outside scope.
* The single reference system is `qemu-dwl-foot`.
* Its acceptance condition is a real QEMU boot into dwl with a real foot terminal and deterministic injected keyboard input.
* Preserve the existing remote package tarball and index format wherever practical. Extending metadata with optional fields is allowed.
* Internal world-cache and PM CLI compatibility is not required.
* Delete legacy world state instead of maintaining migration logic for `.world/state.json`.
* Build and publish must remain separate operations.
* Publication credentials must come from `LAPUTA_TOKEN`; do not store them inside roots or PM state.
* Package build recipes must not rely on ambient `/bin/sh`, `/usr/bin/sh`, `SHELL`, or shell command strings.
* Host-side Docker and QEMU orchestration must use structured `process.command_argv`.
* Do not introduce a general plugin framework, derivation language, daemon, database, garbage collector, user profile system, live-root activation protocol, or distributed builder.
* All new XSH modules with exports require module documentation and exported-declaration documentation.
* Run the checked-out local `xsht` for strict static checking.
* Run actual behavioral tests against the pinned published Linux XSH binaries used by the repositories.
* Keep repository publication fail-closed.
* Use canonical, deterministic encodings. Timestamps, absolute host paths, concurrency levels, credentials, and cache locations must not influence semantic plan or artifact identities.
* Commit after each independently passing task.

---

# 3. Architecture Contract

## 3.1 Ownership Boundary

The final ownership model must be:

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

## 3.2 Canonical Pipeline

The final build pipeline is:

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

Each arrow is an explicit checked boundary.

## 3.3 Principal Invariants

Implement and test these invariants directly:

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

---

# 4. Final File Structure

Use this as the target structure. Slight naming adjustments are acceptable only when an existing convention is materially clearer.

## 4.1 `packages`

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
```

Delete these once migration is complete and no imports remain:

```text
pm/world.xsh
pm/buildroot.xsh
pm/extensions.xsh
```

`pm/install.xsh` may also be deleted after its reusable manifest, metadata, and root-composition logic has moved into focused modules.

## 4.2 `laputa`

```text
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

The final root `Makefile` should contain only thin compatibility aliases. It must no longer encode package sets, Docker volume topology, world resolution, or QEMU mode policy.

---

# 5. Final Public CLI

## 5.1 Package Manager CLI

The final PM command surface is:

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

Remove these legacy public commands:

```text
world-plan
build-install
build-set
build-set-deps
build-upload-set
upload-set
upload-repo-export
refresh-index
auth
help-ext
```

Do not retain heuristic aliases.

The new PM does not promise online mutation of a live `/` in this phase. Immutable generation composition is the supported system-installation primitive. Preserve reusable read-only package database inspection logic where useful, but do not expose a misleadingly transactional `pm install` or `pm remove` until real activation semantics exist.

## 5.2 Laputa CLI

The final system CLI is:

```text
laputa plan qemu-dwl-foot
laputa build qemu-dwl-foot [-j N|--jobs N]
laputa test qemu-dwl-foot
laputa boot qemu-dwl-foot
laputa clean qemu-dwl-foot
```

Behavior:

* `plan` generates and prints the exact package and generation plans without building.
* `build` resolves, builds or imports exact artifacts, composes the root generation, and creates the disk image.
* `test` ensures a current image exists, boots it noninteractively, injects input through QMP, captures a screenshot, and validates console markers.
* `boot` opens the Cocoa QEMU display and launches the normal dwl + foot session.
* `clean` removes profile outputs under `target/laputa/qemu-dwl-foot`; it does not destroy the immutable artifact-store volume.

Do not expose dozens of environment-controlled proof modes. The profile and command determine behavior.

---

# 6. Core Data Types

Implement internal tag unions. Do not represent these domains as arbitrary strings after decoding:

```xsh
export type Target = Aarch64LinuxMusl

export type PackageKind = Payload | Meta

export type DependencyKind =
  Runtime |
  BuildHost |
  BuildTarget |
  Bootstrap

export type SourceKind =
  Auto |
  Archive |
  Zip |
  Cpio |
  File |
  Directory |
  Git

export type FileKind =
  File |
  Binary |
  Symlink |
  Tree

export type PlanAction =
  Build(reason: Str) |
  ReuseRemote(reason: Str)

export type ArtifactOrigin =
  Built |
  Remote

export type ArtifactStatus =
  Complete |
  Invalid(reason: Str)

export type ProofMode =
  DwlFootInput |
  DwlFootInteractive
```

JSON-facing data-transfer records must encode tagged values with validated strings because public tagged JSON is not part of the current XSH contract. Every union therefore needs paired functions such as:

```xsh
export pure dependency_kind_text(kind: DependencyKind) -> Str
export pure parse_dependency_kind(raw: Str) -> Result[DependencyKind]
```

Do not allow direct string matches on dependency, source, file, action, target, or proof kinds outside these encode/decode boundaries.

---

# 7. Implementation Tasks

## Task 0: Establish the Baseline and Materialize the Spec

**Repositories:** `packages`, `laputa`

**Files:**

* Create: `laputa/docs/CORE-INFRASTRUCTURE.md`
* Create: `laputa/docs/DEVELOPMENT.md`
* Modify only if necessary: `packages/AGENTS.md`
* Modify only if necessary: `laputa/AGENTS.md`

### Steps

* [ ] Read all repository instructions before changing code:

```bash
cat ~/d/laputa-systems/xsh/AGENTS.md
cat ~/d/laputa-systems/xsh/docs/IDIOMS.md
cat ~/d/laputa-systems/packages/AGENTS.md
cat ~/d/laputa-systems/laputa/AGENTS.md
```

* [ ] Copy the Architecture Contract, scope, invariants, CLI, and final file structure from this plan into `laputa/docs/CORE-INFRASTRUCTURE.md`.

* [ ] Record the local starting commits in that document under a non-normative “Initial implementation baseline” section.

* [ ] Verify the current PM static checks before refactoring:

```bash
cd ~/d/laputa-systems/packages

~/d/laputa-systems/xsh/target/debug/xsht \
  check --strict \
  pm.xsh \
  pm/*.xsh
```

Expected: PASS.

* [ ] Run the current PM behavioral suite:

```bash
cd ~/d/laputa-systems/packages
make test
```

Expected: PASS.

* [ ] Build the current minimal desktop proof image:

```bash
cd ~/d/laputa-systems/laputa

make dwl-foot-minimal-test \
  LAPUTA_PACKAGES_ROOT="$HOME/d/laputa-systems/packages"
```

Expected: PASS.

* [ ] Run the current automated QEMU visual/input proof using the existing path. Use the repository’s current proven target rather than inventing a new command at this point.

Expected:

```text
laputa-qemu foot-input ok
```

A screenshot must be produced and no kernel panic marker may appear.

* [ ] Save baseline outputs under the ignored directory:

```text
laputa/target/refactor-baseline/
```

Include:

```text
console.log
qemu.log
screenshot.ppm
installed-packages.txt
runtime-manifest.txt
pm-help.txt
world-plan.txt
```

Do not commit generated logs or images.

* [ ] Commit the durable specification:

```bash
git -C ~/d/laputa-systems/laputa add docs/CORE-INFRASTRUCTURE.md docs/DEVELOPMENT.md
git -C ~/d/laputa-systems/laputa commit -m "docs: define core infrastructure architecture"
```

---

## Task 1: Introduce the Typed PM Domain Model

**Repository:** `packages`

**Files:**

* Modify: `pm/types.xsh`
* Create: `pm/recipe.xsh`
* Create: `tests/xsh/pm_recipe.xsh`
* Add or modify fixtures under: `tests/xsh/fixtures/recipe-*`
* Modify imports in current PM modules as required

**Produces:**

```xsh
types.Target
types.PackageKind
types.DependencyKind
types.SourceKind
types.FileKind
types.Package
types.UpstreamSource
types.FileTreeEntry
types.PackageId
types.DependencyEdge

recipe.load_package(dir: Path) -> Result[types.Package]
recipe.call_prepare(pkg: types.Package, src: Path)
recipe.call_build(pkg: types.Package, src: Path, dest: Path)
recipe.call_prepare_sources(pkg: types.Package, src: Path)
```

### Design Requirements

`types.Package` must no longer contain:

```text
exports: Any
extract_install: Bool
```

Dynamic module values are quarantined inside `pm/recipe.xsh`. Planning, graph, store, generation, and publication modules operate only on typed package records.

Because existing package procedures declare differing effect sets, do not force every recipe to satisfy one effect-exact module contract. Use a structural metadata contract for value exports, then validate and call dynamic procedures exclusively through `recipe.xsh`.

A representative metadata contract is:

```xsh
type PackageMetadataModule = module {
  export let name: Str
  export let ver: Str
  export let rel: Str
  export let deps: List[Str]
  export let mkdeps_host: List[Str]
  export optional let mkdeps_target: List[Str]
  export let upstream_sources: List[Record]
  export let filetree: List[Record]
  export optional let package_kind: Str
  export optional let nostrip: Bool
  export optional let source_mirror: Bool
}
```

Decode raw source and filetree records immediately into typed records.

### Required Recipe Invariants

Enforce these in `recipe.load_package`:

* package directory contains `PKGBUILD.xsh`;
* package name is nonempty and matches:

```text
[a-z0-9][a-z0-9+._-]*
```

* production packages under `repo/<name>` have a package name equal to the directory name;
* `ver` is nonempty;
* `rel` is a positive decimal string;
* dependency lists have no duplicates;
* a package may not depend on itself;
* every filetree path is relative, normalized, nonempty, and traversal-free;
* filetree paths are unique;
* source kinds and file kinds are decoded through typed parsers;
* remote URL sources may not use `SKIP`;
* `SKIP` is legal only for repository-local inputs;
* every source applies to `aarch64` or `all`;
* every selected source has exactly one applicable checksum;
* payload packages export `build`;
* payload packages have `proof.xsh`;
* metapackages have no payload filetree;
* metapackages do not silently become payload packages because a source list happened to change;
* optional package procedures are called only through `recipe.xsh`.

Introduce explicit recipe metadata:

```xsh
export let package_kind = "payload"
```

or:

```xsh
export let package_kind = "meta"
```

Migrate every metapackage in `repo/` to declare `package_kind = "meta"`.

Do not continue inferring metapackages from an empty source list after migration.

### Tests

Write failing tests first for:

```text
valid payload package
valid metapackage
invalid package name
directory/name mismatch
duplicate dependency
self-dependency
invalid source kind
invalid file kind
remote SKIP checksum
missing aarch64 checksum
duplicate filetree path
absolute filetree path
parent traversal
payload without build
payload without proof
metapackage with payload files
```

Run:

```bash
cd ~/d/laputa-systems/packages

~/d/laputa-systems/xsh/target/debug/xsht \
  test tests/xsh/pm_recipe.xsh
```

Then run strict checks and the full Docker suite.

### Commit

```bash
git add pm/types.xsh pm/recipe.xsh pm/*.xsh tests/xsh/pm_recipe.xsh tests/xsh/fixtures repo
git commit -m "refactor: add typed package recipe boundary"
```

---

## Task 2: Build One Canonical Catalog and Graph Engine

**Repository:** `packages`

**Files:**

* Create: `pm/catalog.xsh`
* Create: `pm/policy.xsh`
* Create: `pm/graph.xsh`
* Create: `tests/xsh/pm_graph.xsh`
* Modify: `pm/local.xsh`
* Modify: `pm/repo.xsh`
* Modify: legacy `pm/world.xsh` temporarily to use the new graph

**Produces:**

```xsh
catalog.load(root: Path) -> Result[types.PackageCatalog]

graph.edges(
  catalog: types.PackageCatalog,
  policy: types.BuildPolicy,
) -> Result[List[types.DependencyEdge]]

graph.closure(
  catalog: types.PackageCatalog,
  roots: List[Str],
  kinds: List[types.DependencyKind],
) -> Result[List[Str]]

graph.topological_levels(
  selected: List[Str],
  edges: List[types.DependencyEdge],
) -> Result[List[List[Str]]]

graph.runtime_closure(
  catalog: types.PackageCatalog,
  roots: List[Str],
) -> Result[List[Str]]

graph.build_closure(
  catalog: types.PackageCatalog,
  roots: List[Str],
  policy: types.BuildPolicy,
) -> Result[List[Str]]
```

### Catalog Rules

`catalog.load(repo_root)` must:

* discover `repo/*/PKGBUILD.xsh`;
* load every package through `recipe.load_package`;
* return packages sorted by name;
* reject duplicate package names;
* validate that every local dependency exists locally or is available in the selected remote snapshot;
* avoid embedding dynamic recipe modules;
* use paths relative to repository root in durable records.

### Build Policy

Create one explicit policy:

```xsh
policy.aarch64_docker()
```

It declares:

```text
target = aarch64-linux-musl
build target = aarch64-linux-musl
native build = true
```

Bootstrap exceptions must be data in `policy.xsh`, not conditions hidden in graph traversal.

Move current special cases such as musl/LLVM/zlib and gnu-stubs handling into explicit typed seed rules. Include comments explaining why each rule exists and a test for each one.

Remove the implicit “every package depends on laputa-pm” graph edge. PM/XSH execution substrate is executor identity, not a runtime package dependency. A final system includes `laputa-pm` only when its profile requests it.

### Graph Tests

Test:

* deterministic catalog ordering;
* missing dependency;
* duplicate package;
* runtime edge classification;
* host-build edge classification;
* target-build edge classification;
* explicit bootstrap edge classification;
* dependency cycle with a useful cycle path;
* topological levels;
* runtime closure excludes `mkdeps_host`;
* runtime closure excludes `mkdeps_target`;
* build closure includes all required build edges;
* a change in edge kind changes the appropriate closure;
* two calls with the same inputs produce equal lists and levels.

Do not maintain separate graph algorithms in `local`, `repo`, `remote`, and `world`.

Replace those algorithms with adapters around `pm.graph`.

### Commit

```bash
git add pm/catalog.xsh pm/policy.xsh pm/graph.xsh pm/local.xsh pm/repo.xsh pm/world.xsh tests/xsh/pm_graph.xsh tests/xsh/fixtures
git commit -m "refactor: centralize package graph resolution"
```

---

## Task 3: Implement Exact Semantic Fingerprints

**Repository:** `packages`

**Files:**

* Create: `pm/fingerprint.xsh`
* Create or extend: `tests/xsh/pm_plan.xsh`
* Modify: `pm/build.xsh`
* Modify: `pm/sources.xsh`
* Modify: `pm/repo.xsh`

**Produces:**

```xsh
fingerprint.package_build_input(
  repo_root: Path,
  pkg: types.Package,
  target: types.Target,
) -> Result[Str]

fingerprint.package_proof_input(
  repo_root: Path,
  pkg: types.Package,
) -> Result[Str]

fingerprint.pm_tree(pm_root: Path) -> Result[Str]

fingerprint.core_tree(core_root: Path) -> Result[Str]

fingerprint.runners(xsh: Path, xshi: Path, xsht: Path) -> Result[Str]
```

### Package Build Fingerprint

Hash, in stable lexical order:

* package name, version, release, kind, target;
* `PKGBUILD.xsh`;
* all package-local `.xsh` modules except `proof.xsh`;
* `service.xsh`;
* `files/**`;
* `patches/**`;
* declared source URLs;
* source materialization kinds;
* applicable aarch64 source checksums;
* dependency lists and dependency kinds;
* filetree entries and kinds;
* `nostrip`;
* `source_mirror`;
* package build-contract format version.

Do not include:

* `proof.xsh`;
* generated work directories;
* `.git`;
* absolute checkout paths;
* file modification times;
* current time;
* cache paths;
* `--jobs`;
* credentials.

### Proof Fingerprint

Hash:

* package ID;
* `proof.xsh`;
* proof contract format version;
* PM proof module fingerprint.

This separation is required:

* changing build inputs changes the artifact key;
* changing only `proof.xsh` changes the proof key;
* an unchanged artifact can be re-proved.

### PM and Runner Identity

The executor identity must cover:

* `pm.xsh`;
* all semantic `pm/*.xsh` implementation modules;
* the aarch64 Linux `xsh`, `xshi`, and `xsht` binaries;
* mounted XSH `core/` applets;
* an explicit executor format string such as:

```text
laputa-pm-executor-1
```

Do not use timestamps as freshness proxies anywhere in the new planner.

### Tests

Test exact propagation:

```text
same inputs => same digest
mtime-only change => same digest
PKGBUILD change => build digest changes
package-local helper .xsh change => build digest changes
files/** change => build digest changes
service.xsh change => build digest changes
proof.xsh change => build digest unchanged, proof digest changed
PM implementation change => executor digest changed
core applet change => executor digest changed
absolute checkout path change => digest unchanged
```

### Commit

```bash
git add pm/fingerprint.xsh pm/build.xsh pm/sources.xsh pm/repo.xsh tests/xsh/pm_plan.xsh tests/xsh/fixtures
git commit -m "feat: add exact package and executor fingerprints"
```

---

## Task 4: Implement the Deterministic BuildPlan IR

**Repository:** `packages`

**Files:**

* Create: `pm/plan.xsh`
* Create: `pm/plan_json.xsh`
* Extend: `pm/types.xsh`
* Extend: `tests/xsh/pm_plan.xsh`
* Add golden fixture: `tests/xsh/fixtures/plans/basic-aarch64.json`

**Produces:**

```xsh
plan.resolve(
  catalog: types.PackageCatalog,
  remote: types.RemoteSnapshot,
  policy: types.BuildPolicy,
  roots: List[Str],
  all: Bool,
  identity: types.ExecutorIdentity,
) -> Result[types.BuildPlan]

plan.fingerprint(value: types.BuildPlan) -> Result[Str]

plan.render(value: types.BuildPlan, colors: Bool) -> Result[Str]

plan_json.write(path: Path, value: types.BuildPlan)
plan_json.read(path: Path) -> Result[types.BuildPlan]
plan_json.verify(value: types.BuildPlan)
```

### BuildPlan Schema

The durable JSON schema is:

```json
{
  "format": "laputa-build-plan-1",
  "target": "aarch64-linux-musl",
  "roots": ["foot-minimal"],
  "repository_digest": "<sha256>",
  "remote_index_sha256": "<sha256>",
  "executor": {
    "format": "laputa-pm-executor-1",
    "pm_sha256": "<sha256>",
    "xsh_sha256": "<sha256>",
    "core_sha256": "<sha256>"
  },
  "nodes": [
    {
      "name": "example",
      "ver": "1.0.0",
      "rel": "1",
      "package_id": "example-1.0.0-1",
      "recipe_dir": "repo/example",
      "recipe_sha256": "<sha256>",
      "proof_sha256": "<sha256>",
      "artifact_key": "<sha256>",
      "proof_key": "<sha256>",
      "action": "build",
      "reason": "new package",
      "level": 0,
      "dependencies": [
        {
          "name": "musl",
          "kind": "runtime",
          "artifact_key": "<sha256>"
        }
      ],
      "remote": null
    }
  ],
  "plan_sha256": "<sha256>"
}
```

For reused remote artifacts, include exact immutable retrieval information:

```json
{
  "arch": "aarch64",
  "tarball": "packages/aarch64/example/example-1.0.0-1.tar.gz",
  "tarball_sha256": "<sha256>",
  "metadata": "metadata/aarch64/example/example-1.0.0-1.json",
  "metadata_sha256": "<sha256>"
}
```

### Determinism Rules

* Sort roots.
* Sort nodes by topological level, then package name.
* Sort dependency edges by kind, then dependency name.
* Store recipe paths relative to the package repository.
* Omit creation timestamps.
* Compute `plan_sha256` over a canonical line-oriented fingerprint, not over unspecified JSON object ordering.
* On decode, recompute and verify `plan_sha256`.
* Reject unknown schema versions.
* Reject duplicate nodes.
* Reject unresolved dependency references.
* Reject a plan whose artifact key does not match its inputs.
* Reject target values other than `aarch64-linux-musl`.

### Resolution Policy

Preserve the useful current release policy:

* no remote package: build as `new package`;
* local version differs from remote: build;
* same version with local release above remote: build;
* local tuple behind remote: fail and require an explicit declaration bump;
* unchanged local tuple may reuse the exact remote artifact;
* a rebuilt local dependency requires dependent rebuild propagation;
* dependent rebuild propagation requires an explicit release bump when the remote tuple would otherwise be reused;
* do not mutate package releases automatically.

For legacy remote metadata without artifact/recipe fields, derive remote artifact identity from target, package tuple, payload hash, and metadata hash.

For new metadata, verify and use published artifact identity.

### Tests

Test:

* byte-for-byte equal JSON on repeated resolution;
* plan equality in two different checkout directories;
* deterministic root ordering;
* deterministic node ordering;
* new-package reason;
* local-version reason;
* local-release reason;
* dependency-propagation reason;
* declared version behind remote failure;
* digest mismatch rejection;
* unknown format rejection;
* duplicate node rejection;
* changed package input propagates to dependent artifact keys;
* jobs count does not change the plan;
* repository URL does not change semantic identity when content is equal;
* aarch64 aliases normalize before plan creation;
* x86-64 target is rejected.

### Commit

```bash
git add pm/types.xsh pm/plan.xsh pm/plan_json.xsh tests/xsh/pm_plan.xsh tests/xsh/fixtures/plans
git commit -m "feat: add deterministic package build plans"
```

---

## Task 5: Add the New PM Planning CLI Beside the Legacy Executor

**Repository:** `packages`

**Files:**

* Modify: `pm/cli.xsh`
* Modify: `pm.xsh`
* Create: `tests/xsh/pm_cli.xsh`
* Modify: `PM.md`

### Required Commands in This Intermediate State

Implement:

```text
pm repo check
pm repo plan
pm repo show
```

Do not remove legacy build execution yet.

Use one typed command parser. Do not route some commands through `cli.commands`, some through manual `argv[0]` comparisons, and others through filesystem heuristics.

Use explicit command records such as:

```xsh
type RepoPlanArgs = {
  repo: Path,
  all: Bool,
  roots: List[Str],
  target: Str,
  output: Path,
}
```

### CLI Rules

* `pm repo plan` requires exactly one of `--all` or one-or-more `--root`.
* `--target` defaults to `aarch64-linux-musl`.
* Any other target fails.
* `--output` is required for automation.
* A repository default may be discovered only by walking parents for both `pm.xsh` and `repo/`.
* Argument meaning may not depend on whether a path currently contains `PKGBUILD.xsh`.
* Remove root/work/out positional inference from these new commands.
* Human output derives from the same typed plan that is serialized.
* `pm repo show` verifies the plan before rendering it.

### Tests

Verify:

```text
clear top-level help
clear subcommand help
missing --all/--root fails
both --all and --root fail
missing output fails
unsupported target fails
filesystem contents do not reinterpret arguments
plan file is generated
show rejects corrupted plan
show output includes action, reason, level, and artifact-key prefix
```

### Commit

```bash
git add pm.xsh pm/cli.xsh tests/xsh/pm_cli.xsh PM.md
git commit -m "feat: add explicit repository planning CLI"
```

---

## Task 6: Implement the Immutable Artifact Store

**Repository:** `packages`

**Files:**

* Create: `pm/store.xsh`
* Extend: `pm/types.xsh`
* Create: `tests/xsh/pm_store.xsh`

**Produces:**

```xsh
store.path(root: Path, key: Str) -> Path

store.lookup(
  root: Path,
  key: Str,
) -> Result[types.ArtifactReceipt]

store.commit(
  root: Path,
  node: types.PlanNode,
  staged: types.StagedArtifact,
) -> Result[types.ArtifactReceipt]

store.import_remote(
  root: Path,
  node: types.PlanNode,
  remote_repo: Str,
  cache: Path,
) -> Result[types.ArtifactReceipt]

store.verify(
  root: Path,
  key: Str,
) -> Result[types.ArtifactReceipt]
```

### Layout

```text
STORE/
├── v1/
│   ├── sha256/
│   │   └── <artifact-key>/
│   │       ├── artifact.json
│   │       ├── payload.tar.gz
│   │       ├── metadata.json
│   │       └── proof.json
│   ├── locks/
│   │   └── <artifact-key>.lock
│   └── tmp/
│       └── <artifact-key>/
```

Optional source mirrors may be stored next to the artifact:

```text
source.tar.bz2
source.json
```

### Atomic Commit Protocol

For each key:

1. acquire `locks/<key>.lock`;
2. if final directory exists, verify every receipt and return it;
3. remove stale `tmp/<key>`;
4. create `tmp/<key>`;
5. copy staged objects into the temporary directory;
6. hash every object;
7. write `artifact.json` last inside the temporary directory;
8. read and verify the complete temporary artifact;
9. atomically rename `tmp/<key>` to `sha256/<key>`;
10. re-open and verify the final artifact;
11. release the lock.

Never write directly into a final artifact directory.

Never overwrite a complete final artifact.

A corrupt final artifact must fail loudly; do not silently treat it as a cache miss and overwrite it.

### Artifact Receipt

`artifact.json` must include:

```json
{
  "format": "laputa-package-artifact-1",
  "key": "<semantic artifact key>",
  "target": "aarch64-linux-musl",
  "package_id": "name-ver-rel",
  "origin": "built",
  "recipe_sha256": "<sha256>",
  "executor_sha256": "<sha256>",
  "payload_sha256": "<sha256>",
  "metadata_sha256": "<sha256>",
  "proof_key": "<sha256>",
  "proof_sha256": "<sha256>",
  "dependency_keys": ["<sha256>"]
}
```

Remote imports use `"origin": "remote"`.

### Tests

Test:

* missing artifact;
* successful atomic commit;
* exact reuse;
* duplicate concurrent commit serialization through lock;
* incomplete temporary directory ignored;
* final payload corruption detected;
* final receipt corruption detected;
* key/receipt mismatch detected;
* remote download hash mismatch;
* remote metadata mismatch;
* failed staging leaves no final directory;
* final artifact is never overwritten.

### Commit

```bash
git add pm/types.xsh pm/store.xsh tests/xsh/pm_store.xsh
git commit -m "feat: add immutable package artifact store"
```

---

## Task 7: Implement Generic Root Preflight and Composition

**Repository:** `packages`

**Files:**

* Create: `pm/root.xsh`
* Create: `tests/xsh/pm_root.xsh`
* Modify: `pm/local.xsh`
* Modify: `pm/install.xsh`
* Modify: `pm/build.xsh`
* Extend artifact metadata generation

**Produces:**

```xsh
root.preflight(
  artifacts: List[types.ArtifactReceipt],
) -> Result[types.RootPlan]

root.compose(
  output: Path,
  plan: types.RootPlan,
  artifacts: List[types.ArtifactReceipt],
) -> Result[types.RootReceipt]

root.verify(
  output: Path,
  receipt: types.RootReceipt,
)
```

### Artifact Entry Metadata

Stop reconstructing package contents by extracting an archive merely to discover its manifest.

Every artifact metadata sidecar must contain typed entries:

```json
{
  "path": "usr/bin/example",
  "kind": "file",
  "mode": 493,
  "sha256": "<sha256>",
  "target": ""
}
```

For symlinks:

```json
{
  "path": "bin/example",
  "kind": "symlink",
  "mode": 511,
  "sha256": "",
  "target": "../usr/bin/example"
}
```

Represent required empty directories explicitly.

This permits deleting `extract_install`.

### Preflight Rules

Before touching the output root:

* validate every artifact receipt;
* construct the complete ownership map;
* reject duplicate package names;
* reject any path owned by two packages;
* reject traversal paths;
* reject absolute paths;
* reject invalid symlink targets;
* verify dependency artifact keys are present;
* verify file modes are valid;
* verify payload entry hashes;
* compute the root-plan digest.

Do not permit “identical bytes from two packages” as an implicit exception. Ownership must remain singular.

### Composition Protocol

1. preflight completely;
2. compose into `<output>.tmp`;
3. extract/install packages in deterministic package-name order;
4. verify every installed file against metadata;
5. write:

```text
var/lib/laputa/root.json
```

containing the root digest and package artifact keys;

6. rename `<output>.tmp` to `<output>`;
7. never mutate a completed root afterward.

### Tests

Test:

* build dependency excluded when not passed to root composition;
* runtime dependency included;
* collision rejected before output creation;
* path traversal rejected;
* symlink preserved;
* executable mode preserved;
* empty directory preserved;
* payload corruption detected;
* failed composition leaves previous output untouched;
* repeated composition produces equal root receipts;
* output package list is deterministic.

### Commit

```bash
git add pm/root.xsh pm/local.xsh pm/install.xsh pm/build.xsh tests/xsh/pm_root.xsh
git commit -m "feat: add preflighted immutable root composition"
```

---

## Task 8: Refactor Package Build and Proof into an Artifact Executor

**Repository:** `packages`

**Files:**

* Create: `pm/execute.xsh`
* Modify: `pm/build.xsh`
* Modify: `pm/proof.xsh`
* Modify: `pm/sources.xsh`
* Create: `tests/xsh/pm_execute.xsh`
* Add execution fixtures

**Produces:**

```xsh
execute.build_plan(
  plan: types.BuildPlan,
  repo_root: Path,
  store_root: Path,
  remote_repo: Str,
  jobs: Int,
) -> Result[types.BuildResult]

execute.build_node(
  plan: types.BuildPlan,
  node: types.PlanNode,
  repo_root: Path,
  store_root: Path,
  remote_repo: Str,
) -> Result[types.ArtifactReceipt]
```

### Node Execution

For `ReuseRemote`:

1. verify that the plan contains exact remote paths and hashes;
2. import the remote package into the artifact store;
3. do not re-resolve the remote index.

For `Build`:

1. acquire the artifact lock;
2. look up and verify all dependency artifacts;
3. compose a fresh package build root from the exact build closure;
4. seed only the explicit executor substrate;
5. prepare sources;
6. load the recipe through `recipe.xsh`;
7. build one package;
8. create payload and metadata;
9. compose a separate proof root containing:

   * runtime dependency closure;
   * candidate package;
   * proof executor substrate;
10. run the package proof;
11. create the proof receipt;
12. commit the package artifact atomically;
13. remove the temporary package roots.

Do not reuse a mutable root between packages.

Do not pass previously built package objects through an accumulating in-memory `built` list as hidden dependency state.

### Executor Substrate

Explicitly fingerprint and seed:

```text
xsh
xshi
xsht
PM modules
XSH core applets
minimal filesystem directories
```

Do not model those files as an implicit `laputa-pm` runtime dependency edge.

### Parallelism

Use the plan’s deterministic topological levels.

For each level:

```text
already complete artifacts => verify and reuse
remote nodes => import
build nodes => bounded par-map with --jobs
```

Do not attempt a new cross-level asynchronous scheduler in this migration. Correct isolated nodes and exact cache reuse are more important. A future work-conserving scheduler can consume the same plan without changing semantics.

### Resume Semantics

The immutable store is the source of truth.

A second run:

* verifies and reuses complete matching artifacts;
* rebuilds nothing merely because a process was interrupted;
* ignores stale temporary directories after acquiring the corresponding lock;
* does not need a mutable `.world/state.json`.

A small build-run receipt may report progress, but it must not determine correctness.

### Failure Behavior

A failed node must:

* preserve its build log;
* report package ID, phase, and log path;
* not create a final artifact;
* not modify dependency artifacts;
* not modify prior root generations;
* cause the current level and overall build to fail.

### Tests

Test:

* one local package build;
* dependency build before dependent;
* isolated roots;
* build-host package available during build;
* build-host package absent from proof runtime unless also a runtime dependency;
* proof failure prevents artifact commit;
* interrupted build resumes by exact artifact key;
* warm run reuses all artifacts;
* changed recipe rebuilds package and dependents;
* changed proof re-proves without changing payload artifact identity;
* remote reuse does not download the mutable index during execution;
* corrupt cached artifact fails;
* parallel same-level packages do not share files.

### Commit

```bash
git add pm/execute.xsh pm/build.xsh pm/proof.xsh pm/sources.xsh tests/xsh/pm_execute.xsh tests/xsh/fixtures
git commit -m "refactor: execute plans through isolated package artifacts"
```

---

## Task 9: Make Repository Publication Consume Completed Plans

**Repository:** `packages`

**Files:**

* Modify: `pm/repo.xsh`
* Extend: `pm/types.xsh`
* Extend: `tests/xsh/pm_repo.xsh`
* Modify: `pm/remote.xsh`

**Produces:**

```xsh
repo.snapshot(
  plan: types.BuildPlan,
  store_root: Path,
) -> Result[types.RepoSnapshot]

repo.publish(
  snapshot: types.RepoSnapshot,
  remote_repo: Str,
  token: Str,
  work: Path,
)
```

### Publication Rules

* A snapshot is generated only from a verified BuildPlan.
* Every `Build` node must have a complete proved artifact.
* Every reused remote node must have a verified imported artifact.
* Publication may not trigger a build.
* Publication may not resolve a new remote index except for final conflict checking.
* Upload payloads, metadata, proof metadata, and source mirrors first.
* Write the remote index last.
* If any object upload fails, do not switch the index.
* If the same architecture/name/version/release already exists with the same hashes, report `already-published`.
* If that tuple exists with different bytes or metadata, fail.
* Never overwrite an immutable package tuple.
* Do not write credentials to disk.
* Do not invoke global lifecycle hooks.

### Metadata Extension

New metadata sidecars should include optional fields:

```json
{
  "artifact_key": "<sha256>",
  "recipe_sha256": "<sha256>",
  "executor_sha256": "<sha256>",
  "proof_key": "<sha256>",
  "proof_sha256": "<sha256>"
}
```

The decoder must continue accepting legacy metadata without these fields.

Do not require an immediate rebuild of every published package solely to populate the optional fields.

### Tests

Use `file://` remotes to test:

* complete snapshot;
* incomplete artifact set rejection;
* unproved artifact rejection;
* payload uploaded before index;
* failed object upload leaves old index;
* exact republish is idempotent;
* conflicting tuple fails;
* metadata extension round-trip;
* legacy metadata still imports;
* token absent fails only for network publication, not snapshot generation.

### Commit

```bash
git add pm/types.xsh pm/repo.xsh pm/remote.xsh tests/xsh/pm_repo.xsh
git commit -m "refactor: publish verified repository snapshots"
```

---

## Task 10: Add Root Generation Planning

**Repository:** `packages`

**Files:**

* Create: `pm/generation.xsh`
* Extend: `pm/types.xsh`
* Extend: `tests/xsh/pm_root.xsh`

**Produces:**

```xsh
generation.plan(
  build_plan: types.BuildPlan,
  runtime_roots: List[Str],
  overlay_digest: Str,
) -> Result[types.GenerationPlan]

generation.compose(
  plan: types.GenerationPlan,
  store_root: Path,
  output_root: Path,
  overlay_root: Path,
) -> Result[types.GenerationReceipt]
```

### GenerationPlan

The plan must include:

```text
format
target
source BuildPlan digest
runtime roots
runtime package closure
artifact keys
overlay digest
generation digest
```

Runtime closure follows only `Runtime` edges.

`BuildHost`, `BuildTarget`, and `Bootstrap` edges must not enter the final generation unless a package is independently reachable through a runtime edge or explicitly named as a runtime root.

### Overlay Rules

The overlay is explicit profile-owned content such as:

```text
guest proof script
profile-specific inittab or service declaration
static configuration
```

Hash the overlay tree and include its digest in generation identity.

Apply overlays only after package collision preflight. Overlay paths must also have singular ownership and may overwrite package files only through an explicit profile replacement declaration. The initial `qemu-dwl-foot` profile should not require arbitrary package overwrites.

### Generation Output

A complete generation contains:

```text
var/lib/laputa/generation.json
```

with:

```json
{
  "format": "laputa-generation-1",
  "generation_sha256": "<sha256>",
  "build_plan_sha256": "<sha256>",
  "profile": "qemu-dwl-foot",
  "target": "aarch64-linux-musl",
  "runtime_roots": [],
  "artifacts": []
}
```

### Required Runtime-Purity Test

Create a fixture where:

```text
app runtime-depends on lib
app build-depends on compiler
```

The composed generation must contain `app` and `lib`, and must not contain `compiler`.

### Commit

```bash
git add pm/types.xsh pm/generation.xsh tests/xsh/pm_root.xsh tests/xsh/fixtures
git commit -m "feat: add immutable system root generations"
```

---

## Task 11: Cut Over and Simplify the PM CLI

**Repository:** `packages`

**Files:**

* Rewrite: `pm/cli.xsh`
* Modify: `pm.xsh`
* Modify: `Makefile`
* Rewrite: `PM.md`
* Update: `LAPUTA.md`
* Split or rewrite: `tests/xsh/pm.xsh`
* Delete after callers migrate:

  * `pm/world.xsh`
  * `pm/buildroot.xsh`
  * `pm/extensions.xsh`
  * obsolete portions or entirety of `pm/install.xsh`

### Required Final Commands

Implement the final CLI listed in Section 5.1.

`pm repo build` must call `execute.build_plan`.

`pm repo publish` must call `repo.snapshot` and `repo.publish`.

`pm root compose` must call `generation.plan` and `generation.compose`.

`pm store verify` must walk final store entries and verify each one.

### Delete Ambiguous and Non-Deterministic Surface

Remove:

* root/work/out positional guessing;
* package-name versus package-directory inference;
* generic `pm-*` extension fallback;
* `XSH_PM_HOOKS`;
* `LAPUTA_HOOK`;
* stored auth tokens;
* `pm auth`;
* `build-set`;
* `build-upload-set`;
* `world-plan --build`;
* `world-plan --upload`;
* native-cross environment branches;
* generated native-cross compiler wrapper scripts;
* global mutable world roots;
* `.world/state.json`;
* `XSH_PM_REUSE_SET_ROOTS`;
* stale-world cache cleanup advice;
* command names in `PmContext`;
* string comparisons that alter execution based on the caller’s command name.

Replace command-shaped context with capability-shaped records. For example:

```xsh
type BuildContext = {
  repo_root: Path,
  work_root: Path,
  store_root: Path,
  target: Target,
  executor: ExecutorIdentity,
}
```

### Remove Package Install Hooks

Search:

```bash
rg -n \
  'pre_install|post_install|pre_remove|post_remove|extract_install' \
  ~/d/laputa-systems/packages
```

For each production recipe:

* move deterministic file creation into `build`;
* declare resulting files in `filetree`;
* replace imperative install-time behavior with service/config payloads;
* add or strengthen the package proof;
* remove the hook or escape hatch.

Do not merely retain hidden compatibility adapters.

### Test Suite Reorganization

Split the current monolithic PM tests by domain. Preserve behavior-oriented tests; do not mechanically duplicate every old assertion.

Final mandatory suites:

```text
pm_recipe.xsh
pm_graph.xsh
pm_plan.xsh
pm_store.xsh
pm_root.xsh
pm_execute.xsh
pm_repo.xsh
pm_cli.xsh
```

Update `Makefile` so `make test` runs all of them in the Docker test image with coverage.

### Verification

```bash
cd ~/d/laputa-systems/packages

~/d/laputa-systems/xsh/target/debug/xsht \
  check --strict \
  pm.xsh \
  pm/*.xsh \
  tests/xsh/*.xsh

make test
```

Search for legacy terms:

```bash
rg -n \
  'world-plan|build-set|build-install|XSH_PM_HOOKS|LAPUTA_HOOK|XSH_PM_NATIVE_CROSS|\.world/state\.json|explicit_context_is_likely|args_are_package_dirs' \
  pm.xsh pm tests PM.md LAPUTA.md
```

Expected: no active implementation references. Historical migration notes are unnecessary.

### Commit

```bash
git add -A
git commit -m "refactor: replace legacy PM workflows with planned artifacts"
```

---

## Task 12: Create the Typed Laputa System Profile and CLI

**Repository:** `laputa`

**Files:**

* Create: `laputa.xsh`
* Create: `laputa/types.xsh`
* Create: `laputa/profile.xsh`
* Create: `laputa/cli.xsh`
* Create: `laputa/docker.xsh`
* Create: `laputa/build.xsh`
* Create: `profiles/qemu-dwl-foot.xsh`
* Create: `tests/xsh/profile.xsh`
* Create: `tests/xsh/docker.xsh`

### Core Types

```xsh
export type SystemTarget = Aarch64LinuxMusl

export type DisplayMode =
  Headless |
  Cocoa

export type QemuMode =
  Test |
  Interactive

export type SessionSpec = {
  compositor: Path,
  terminal: Path,
  interactive_argv: List[Str],
  proof_argv: List[Str],
}

export type QemuSpec = {
  machine: Str,
  cpu: Str,
  smp: Int,
  memory: Str,
  width: Int,
  height: Int,
}

export type ProofSpec = {
  success_markers: List[Str],
  failure_markers: List[Str],
  input_text: Str,
  screenshot_required: Bool,
}

export type SystemProfile = {
  name: Str,
  target: SystemTarget,
  package_roots: List[Str],
  kernel_package: Str,
  kernel_path: Path,
  session: SessionSpec,
  qemu: QemuSpec,
  proof: ProofSpec,
  forbidden_packages: List[Str],
  forbidden_sonames: List[Str],
}
```

### Profile Module Contract

```xsh
type SystemProfileModule = module {
  export let profile: types.SystemProfile
}
```

Load profiles through:

```xsh
profile.load(name: Str, profiles_root: Path)
```

The profile name must be a simple filename stem, not an arbitrary path.

### `qemu-dwl-foot` Intent

Use exactly these direct runtime roots unless characterization proves one is redundant:

```text
baselayout
xsh
laputa-pm
xinit
mdevd
seatd
dwl-minimal
foot-minimal
```

The Linux kernel is selected separately:

```text
linux
```

Do not list transitive libraries in the profile.

The resolver computes those.

The initial normal session is:

```text
/usr/bin/dwl -s "/usr/bin/foot /bin/xshi --no-config"
```

The proof session launches foot with the guest proof program.

### Forbidden Runtime Packages

At minimum reject these from the final generation unless a later explicitly approved profile changes the contract:

```text
llvm-toolchain
pkgconf
cmake
muon
samurai
m4
flex
bison
wayland-dev
wayland-protocols
pixman-dev
dbus
systemd
xwayland
gtk
pango
pipewire
pulseaudio
python
```

Preserve and centralize the existing forbidden SONAME assertions for the minimal dwl/foot stack.

### Docker Adapter

`laputa/docker.xsh` owns all Docker command construction.

Use:

```text
--platform linux/arm64
```

Mount:

```text
packages checkout read-only
laputa checkout read-only
xsh/core read-only
laputa target output writable
artifact-store named volume writable
source-cache named volume writable
```

Named volumes:

```text
laputa-artifacts-aarch64-v1
laputa-sources-aarch64-v1
```

Verify the runner image reports `arm64`. Reject an amd64 image instead of relying on emulation.

Do not mount a shared mutable world root.

### Host Configuration

Allow only a small explicit configuration surface:

```text
LAPUTA_PACKAGES_ROOT
XSH_SOURCE_ROOT
XSH_HOST
LAPUTA_REPO_URL
LAPUTA_TOKEN
DOCKER
QEMU_SYSTEM_AARCH64
```

`LAPUTA_TOKEN` is relevant only to an eventual explicit publish operation, not profile building.

All other build and proof choices come from CLI arguments or the profile.

### Profile Tests

Test:

* known profile loads;
* unknown profile fails;
* profile target is aarch64;
* duplicate roots fail;
* absolute/invalid package names fail;
* kernel package is not duplicated as an ordinary accidental root;
* profile digest is deterministic;
* runtime roots are exactly the declared intent;
* Docker command uses `linux/arm64`;
* Docker mounts package and source repositories read-only;
* no x86-64 environment or platform option appears.

### Commit

```bash
git add laputa.xsh laputa profiles tests/xsh docs
git commit -m "feat: add typed qemu dwl foot system profile"
```

---

## Task 13: Build Profile Generations and Atomic Disk Images

**Repository:** `laputa`

**Files:**

* Create or complete: `laputa/build.xsh`
* Create: `laputa/image.xsh`
* Create: `tests/xsh/image.xsh`
* Move focused code out of: `boot.xsh`
* Reuse package-side `pm.plan`, `pm.execute`, and `pm.generation`

### Build Flow

`laputa build qemu-dwl-foot` must:

1. load and validate the profile;
2. launch the native arm64 Linux build container;
3. create a package BuildPlan for:

   * profile package roots;
   * kernel package;
4. save it to:

```text
target/laputa/qemu-dwl-foot/build-plan.json
```

5. execute the plan against the artifact-store volume;
6. create a GenerationPlan from the runtime roots;
7. save it to:

```text
target/laputa/qemu-dwl-foot/generation-plan.json
```

8. compose the immutable generation;
9. verify forbidden packages and SONAMEs;
10. extract the kernel from the exact kernel artifact path declared by the profile;
11. create ext4 and GPT images;
12. atomically publish final host outputs.

### Output Layout

```text
target/laputa/qemu-dwl-foot/
├── build-plan.json
├── generation-plan.json
├── generation.json
├── rootfs.ext4
├── disk.img
├── vmlinuz
├── build.log
├── console.log
├── qemu.log
├── qmp.sock
└── screenshot.ppm
```

Temporary files use `.tmp` suffixes and are renamed only after verification.

### Image Module

Move these responsibilities from `boot.xsh` into `laputa/image.xsh`:

* image size parsing;
* ext4 creation invocation;
* GPT protective MBR;
* GPT entries;
* GPT headers;
* root partition placement;
* final image verification.

Keep the existing native XSH ext4 implementation.

Do not hardcode a kernel filename containing a kernel version. Resolve the profile’s declared `kernel_path` from artifact metadata.

### Root Filesystem Sizing

Calculate rootfs size from the composed generation:

```text
used bytes
+ 25 percent
+ 64 MiB
```

Round upward to a MiB boundary.

Enforce a minimum of 256 MiB for the graphical reference profile.

Do not retain unrelated fixed image-size modes.

### Image Tests

Test:

* deterministic generation digest;
* kernel extraction by declared manifest path;
* missing kernel path fails;
* rootfs size calculation;
* protective MBR signature;
* GPT header signature;
* expected root partition GUID;
* PARTUUID matches kernel command line;
* incomplete image never replaces prior final image;
* output image is nonempty and has expected partition bounds.

### Commit

```bash
git add laputa/build.xsh laputa/image.xsh tests/xsh/image.xsh boot.xsh
git commit -m "feat: compose profile generations and disk images"
```

---

## Task 14: Replace the Monolithic Boot Harness with Focused QEMU and Proof Modules

**Repository:** `laputa`

**Files:**

* Create: `laputa/qemu.xsh`
* Create: `laputa/proof.xsh`
* Create: `guest/qemu-dwl-foot-proof.xsh`
* Create: `tests/xsh/qemu.xsh`
* Keep and narrow: `boot/qmp-proof.py`
* Delete or reduce after cutover:

  * `proof-stage.xsh`
  * large QEMU portions of `boot.xsh`

### QEMU Configuration

For `qemu-dwl-foot`, use:

```text
machine: virt,accel=hvf,highmem=off
cpu: host
smp: 2
memory: 1536M
kernel: target profile vmlinuz
disk: virtio-blk-device
network: user + virtio-net-pci
GPU: virtio-gpu-pci, 1280x800
input:
  virtio-keyboard-pci
  virtio-tablet-pci
  virtio-mouse-pci
serial: stdio/log capture
QMP: Unix socket
no reboot
```

Kernel command line must include the existing proven ARM serial console and root PARTUUID, plus only the proof mode needed by the command.

Do not carry forward:

```text
audio proof
Tailscale proof
Mesa expansion proof
generic debug mode
x86-64 devices
multiple GPU-selection environment variables
multiple root-source modes
Docker-image fallback guessing
```

### Host QEMU Supervisor

Implement the supervisor in XSH:

* spawn QEMU;
* capture stdout and stderr to explicit files;
* poll console output;
* terminate on panic/failure marker;
* invoke QMP helper after the graphical session is ready;
* inject deterministic text;
* capture screenshot;
* enforce timeout;
* terminate QEMU cleanly;
* kill it only when graceful termination fails;
* verify final markers;
* print paths to logs and screenshot on failure.

Do not embed a large `sh -c` watcher.

### Guest Proof

`guest/qemu-dwl-foot-proof.xsh` should contain only the canonical test:

1. settle devices with mdevd;
2. prove expected input devices exist;
3. start seatd;
4. wait for `/run/seatd.sock`;
5. create `XDG_RUNTIME_DIR`;
6. launch dwl with pixman renderer and DRM/libinput backends;
7. launch foot inside dwl;
8. run a small XSH program inside foot that:

   * prints a stable visual marker;
   * reads stdin;
   * writes input to `/run/laputa-foot-input.txt`;
9. QMP injects:

```text
laputa
```

and EOF;

10. guest verifies the file contains the expected input;
11. guest prints:

```text
LAPUTA_DWL_FOOT_PROOF_OK
```

to `/dev/console`.

Failure prints:

```text
LAPUTA_DWL_FOOT_PROOF_FAILED
```

with a concise phase and message.

### Required Failure Markers

Host supervision must fail on:

```text
Kernel panic
not syncing
Attempted to kill init
Insufficient stack space
LAPUTA_DWL_FOOT_PROOF_FAILED
```

### Interactive Mode

`laputa boot qemu-dwl-foot`:

* uses Cocoa display;
* launches the profile’s normal dwl + foot session;
* attaches serial output;
* does not inject input;
* does not terminate after a proof marker;
* exits when QEMU exits or the user closes the VM.

### Automated Mode

`laputa test qemu-dwl-foot`:

* uses a noninteractive display configuration compatible with QMP screendump;
* captures the screenshot;
* injects input;
* waits for `LAPUTA_DWL_FOOT_PROOF_OK`;
* terminates QEMU;
* verifies screenshot existence;
* prints one final success line:

```text
laputa test qemu-dwl-foot: ok
```

### Tests

Unit-test command construction and marker parsing without QEMU.

Then run the actual QEMU acceptance test.

### Commit

```bash
git add laputa/qemu.xsh laputa/proof.xsh guest/qemu-dwl-foot-proof.xsh tests/xsh/qemu.xsh boot/qmp-proof.py boot.xsh proof-stage.xsh
git commit -m "refactor: isolate qemu execution and dwl foot proof"
```

---

## Task 15: Prove Runtime Purity and Cache Semantics End to End

**Repositories:** `packages`, `laputa`

This task is not optional cleanup. It validates the central design.

### Cold Build

Remove only profile outputs:

```bash
cd ~/d/laputa-systems/laputa

"$HOME/d/laputa-systems/xsh/target/debug/xsh" \
  laputa.xsh -- clean qemu-dwl-foot
```

For a genuinely cold artifact-store test, explicitly remove the test store volume:

```bash
docker volume rm laputa-artifacts-aarch64-v1
docker volume create laputa-artifacts-aarch64-v1
```

Build:

```bash
"$HOME/d/laputa-systems/xsh/target/debug/xsh" \
  laputa.xsh -- build qemu-dwl-foot --jobs 4
```

Expected:

* plan generated;
* exact remote packages imported;
* changed/new local packages built;
* every built package proved;
* immutable generation created;
* image created;
* no x86-64 container;
* no mutable world root.

### Runtime Closure Audit

Inspect generation metadata and package DB.

Assert that intended roots and runtime dependencies are present.

Assert at minimum that these are absent unless also explicitly runtime-required:

```text
llvm-toolchain
pkgconf
cmake
muon
samurai
m4
flex
bison
wayland-dev
wayland-protocols
pixman-dev
```

Run the ELF dependency audit against every ELF in the generation.

Verify there are no undeclared runtime-provider edges.

### Warm Build

Run the same command again:

```bash
"$HOME/d/laputa-systems/xsh/target/debug/xsh" \
  laputa.xsh -- build qemu-dwl-foot --jobs 4
```

Expected:

* identical BuildPlan digest;
* identical GenerationPlan digest;
* every matching artifact reports verified reuse;
* no package rebuild;
* no root-generation content change;
* no image content change when all inputs are unchanged.

### Dependency Invalidation

In a disposable test fixture, not a production recipe:

1. build a dependency and dependent;
2. edit a semantic dependency input;
3. regenerate plan;
4. verify both artifact keys change;
5. verify an unrelated package key does not change.

### Proof-Only Invalidation

In a fixture:

1. build and prove package;
2. edit only `proof.xsh`;
3. verify payload artifact key remains equal;
4. verify proof key changes;
5. re-run proof;
6. verify payload does not rebuild.

### Interrupted Build

In a fixture with two same-level packages:

1. allow first artifact to complete;
2. force second fixture proof to fail;
3. verify first final artifact remains valid;
4. fix the fixture;
5. rerun;
6. verify first is reused and only second continues.

Do not add public failure-injection flags solely for this test. Use purpose-built fixture recipes.

### Corruption Detection

Copy or create a test store and mutate one stored payload byte.

Run:

```text
pm store verify
```

Expected: failure naming the exact artifact and hash mismatch.

Do not silently rebuild over corruption.

### Actual QEMU Test

```bash
cd ~/d/laputa-systems/laputa

"$HOME/d/laputa-systems/xsh/target/debug/xsh" \
  laputa.xsh -- test qemu-dwl-foot
```

Required outputs:

```text
target/laputa/qemu-dwl-foot/console.log
target/laputa/qemu-dwl-foot/qemu.log
target/laputa/qemu-dwl-foot/screenshot.ppm
```

Required console marker:

```text
LAPUTA_DWL_FOOT_PROOF_OK
```

Required absence:

```text
Kernel panic
not syncing
LAPUTA_DWL_FOOT_PROOF_FAILED
```

### Commits

Commit any test fixes in the repository they belong to:

```bash
git -C ~/d/laputa-systems/packages add -A
git -C ~/d/laputa-systems/packages commit -m "test: prove artifact and generation invariants"

git -C ~/d/laputa-systems/laputa add -A
git -C ~/d/laputa-systems/laputa commit -m "test: prove qemu dwl foot system end to end"
```

Skip an empty commit if no source changed.

---

## Task 16: Remove Legacy Laputa Core Paths

**Repository:** `laputa`

**Files to remove or radically reduce:**

```text
Dockerfile.dwl-foot-minimal
proof-dwl-foot-minimal.xsh
boot.xsh
proof-stage.xsh
linux-iteration.xsh portions superseded by laputa CLI
root Makefile world-build and dwl-foot package-list machinery
tools/sync-docker-volume.sh if no remaining caller needs it
```

Do not remove installer-specific files merely because they are not part of this effort. Keep installer code isolated and compiling, but do not migrate or test it on real hardware.

### Makefile End State

Keep thin aliases:

```make
.PHONY: plan build test boot clean pm-test

plan:
	$(XSH_HOST) laputa.xsh -- plan qemu-dwl-foot

build:
	$(XSH_HOST) laputa.xsh -- build qemu-dwl-foot

test:
	$(XSH_HOST) laputa.xsh -- test qemu-dwl-foot

boot:
	$(XSH_HOST) laputa.xsh -- boot qemu-dwl-foot

clean:
	$(XSH_HOST) laputa.xsh -- clean qemu-dwl-foot

pm-test:
	$(MAKE) -C $(LAPUTA_PACKAGES_ROOT) test
```

Installer aliases may delegate to installer-specific scripts, but the root Makefile must not retain the previous world-plan environment matrix.

### Required Searches

```bash
cd ~/d/laputa-systems/laputa

rg -n \
  'Dockerfile\.dwl-foot-minimal|world-plan|WORLD_TO_TRANCHE|WORLD_UPLOAD|XSH_PM_NATIVE_CROSS|XSH_BOOT_QEMU_AUDIO|XSH_BOOT_TAILSCALE|XSH_BOOT_QEMU_MESA|XSH_BOOT_QEMU_DEBUG|XSH_BOOT_ROOTFS_IMAGE' \
  .
```

Expected: no active core implementation references.

### Commit

```bash
git add -A
git commit -m "refactor: retire legacy laputa core orchestration"
```

---

## Task 17: Rewrite Durable Documentation and CI

**Repositories:** `packages`, `laputa`

## `packages` Documentation

Rewrite `PM.md` around:

```text
package contract
typed package kinds
catalog validation
dependency kinds
BuildPlan
artifact store
proof identity
root composition
repository snapshots
final CLI
aarch64-only support
```

Update `LAPUTA.md` to explain the package-side ownership boundary.

Review and digest:

```text
M4.md
SH-TODO.md
TODO.md
```

Delete them if their unimplemented durable requirements have been moved to focused documentation or explicit future-scope notes.

Do not retain milestone-named architecture documentation.

## `laputa` Documentation

`docs/DEVELOPMENT.md` must include exact commands for:

```text
static check
PM test
profile plan
profile build
profile test
interactive boot
clean outputs
verify store
inspect generation
```

`docs/QEMU.md` must document:

```text
required Homebrew QEMU
HVF
output paths
QMP proof
success/failure markers
how to inspect logs
why browsers and hardware are excluded
```

Digest relevant durable material from:

```text
HANDOFF.md
PLANNER-TODO.md
WORLD-BUILD-TODO.md
PLAYBOOK-WORLD-BUILD.md
USERSPACE-TODO.md
boot.md
LINUX.md
```

Delete stale planning documents after preserving unimplemented requirements in focused documentation. Do not preserve chronology merely for history.

## CI

### `packages`

Update `.github/workflows/laputa-package-publish.yml` to use:

```text
pm repo plan
pm repo build
pm repo publish
```

Restrict the migrated workflow to arm64/aarch64.

Do not retain an amd64 matrix that invokes removed PM commands.

### `laputa`

Update `.github/workflows/laputa-validate.yml` to:

1. install the pinned published aarch64 or appropriate host-check XSH tools;
2. strict-check all new XSH modules;
3. run profile unit tests;
4. run PM fixture tests where practical;
5. generate `qemu-dwl-foot` BuildPlan;
6. verify runtime closure excludes build-only packages.

Do not claim GitHub CI proves HVF QEMU. The actual QEMU acceptance gate remains the local macOS command.

Retire or disable legacy amd64/bootstrap workflows that invoke removed commands. Do not port them during this aarch64-only effort.

### Commits

```bash
git -C ~/d/laputa-systems/packages add -A
git -C ~/d/laputa-systems/packages commit -m "docs: document planned artifact package manager"

git -C ~/d/laputa-systems/laputa add -A
git -C ~/d/laputa-systems/laputa commit -m "docs: document profile build and qemu proof"
```

---

# 8. Final Verification Gates

Do not declare completion until every gate passes.

## 8.1 Static PM Checks

```bash
cd ~/d/laputa-systems/packages

~/d/laputa-systems/xsh/target/debug/xsht \
  check --strict \
  pm.xsh \
  pm/*.xsh \
  tests/xsh/*.xsh
```

Expected: PASS with no strict-check errors.

## 8.2 PM Behavioral Tests

```bash
cd ~/d/laputa-systems/packages
make test
```

Expected: PASS.

Inspect coverage for untested new public procedures. Add behavior-oriented tests where a new contract is otherwise unprotected. Do not add trivial coverage padding.

## 8.3 Laputa Static Checks

```bash
cd ~/d/laputa-systems/laputa

~/d/laputa-systems/xsh/target/debug/xsht \
  check --strict \
  laputa.xsh \
  laputa/*.xsh \
  profiles/*.xsh \
  guest/*.xsh \
  tests/xsh/*.xsh
```

Expected: PASS.

## 8.4 Laputa Unit Tests

Run all `laputa/tests/xsh/*.xsh` through `xsht test`.

Expected: PASS.

## 8.5 Plan Determinism

Run twice from clean profile output:

```bash
cd ~/d/laputa-systems/laputa

~/d/laputa-systems/xsh/target/debug/xsh \
  laputa.xsh -- plan qemu-dwl-foot

cp target/laputa/qemu-dwl-foot/build-plan.json /tmp/laputa-plan-1.json

~/d/laputa-systems/xsh/target/debug/xsh \
  laputa.xsh -- plan qemu-dwl-foot

cmp \
  /tmp/laputa-plan-1.json \
  target/laputa/qemu-dwl-foot/build-plan.json
```

Expected: byte-for-byte equal.

## 8.6 Store Verification

```bash
# Run through the Linux arm64 PM container using the laputa CLI adapter.
laputa store verify
```

If no top-level Laputa store command is intentionally exposed, invoke the exact internal Docker-backed `pm store verify` command documented in `DEVELOPMENT.md`.

Expected: every artifact verifies.

## 8.7 Runtime Closure

Inspect generation metadata.

Required direct roots:

```text
baselayout
xsh
laputa-pm
xinit
mdevd
seatd
dwl-minimal
foot-minimal
```

Required absence of build-only tools unless independently runtime-required:

```text
llvm-toolchain
pkgconf
cmake
muon
samurai
m4
flex
bison
wayland-dev
wayland-protocols
pixman-dev
```

## 8.8 Cold and Warm Build

Cold:

```bash
~/d/laputa-systems/xsh/target/debug/xsh \
  laputa.xsh -- build qemu-dwl-foot --jobs 4
```

Warm:

```bash
~/d/laputa-systems/xsh/target/debug/xsh \
  laputa.xsh -- build qemu-dwl-foot --jobs 4
```

Expected warm behavior:

* all matching artifacts reused;
* no package rebuild;
* same plan digest;
* same generation digest;
* same image hash.

## 8.9 QEMU Acceptance

```bash
~/d/laputa-systems/xsh/target/debug/xsh \
  laputa.xsh -- test qemu-dwl-foot
```

Expected:

```text
laputa test qemu-dwl-foot: ok
```

Required artifacts:

```text
console.log
qemu.log
screenshot.ppm
disk.img
vmlinuz
generation.json
```

## 8.10 Legacy-Surface Search

In `packages`:

```bash
rg -n \
  'world-plan|build-set|build-install|XSH_PM_NATIVE_CROSS|XSH_PM_HOOKS|LAPUTA_HOOK|\.world/state\.json|explicit_context_is_likely|args_are_package_dirs' \
  pm.xsh pm tests PM.md LAPUTA.md
```

In `laputa`:

```bash
rg -n \
  'Dockerfile\.dwl-foot-minimal|WORLD_TO_TRANCHE|WORLD_UPLOAD|XSH_BOOT_QEMU_AUDIO|XSH_BOOT_TAILSCALE|XSH_BOOT_QEMU_MESA|XSH_BOOT_QEMU_DEBUG|XSH_BOOT_ROOTFS_IMAGE' \
  .
```

Expected: no active core implementation references.

## 8.11 Repository Status

```bash
git -C ~/d/laputa-systems/packages status --short
git -C ~/d/laputa-systems/laputa status --short
```

Expected: clean, except ignored generated outputs.

---

# 9. Completion Criteria

The work is complete only when all of the following are true:

* Package metadata is validated into typed records.
* Dynamic `Any` module use is quarantined to the recipe adapter.
* There is one graph implementation.
* There is one deterministic BuildPlan.
* Plans survive JSON round-trip with digest verification.
* Build execution consumes plans rather than resolving again.
* Package builds use isolated exact dependency roots.
* Package artifacts are immutable and atomically committed.
* Package proofs have separate identities.
* Restarting a build reuses complete artifacts.
* Corruption is detected rather than overwritten.
* Repository publication consumes complete verified artifacts.
* The remote index switches last.
* Final root generations contain runtime closure only.
* `wayland-dev`, `pixman-dev`, and compiler/build tools do not leak into `qemu-dwl-foot`.
* `qemu-dwl-foot` package intent is declared once.
* The Dockerfile no longer contains a handwritten package closure.
* QEMU configuration is typed and profile-owned.
* Host QEMU supervision is XSH rather than embedded shell.
* The existing QMP Python helper is narrow and focused.
* Automated QEMU input reaches a real foot terminal inside real dwl.
* A screenshot and success marker prove the result.
* Legacy world-plan and mutable-world code is deleted.
* The PM CLI is explicit and non-heuristic.
* New infrastructure is aarch64-only.
* No x86-64 build or test was required.
* No browser or real-hardware work was added.
* Documentation reflects the resulting system rather than the migration history.
* Both repositories are clean and contain coherent, reviewable commits.

