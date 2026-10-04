# Package Manager

`pm.xsh` is the typed Laputa package manager. It turns package recipes into a
deterministic `BuildPlan`, executes only that plan through immutable artifacts,
publishes verified snapshots, and composes runtime-only root generations.
Publication validates package identity before adding artifact and proof fields;
additional recipe metadata survives that augmentation unchanged.

## Package Contract

Recipes live at `repo/<package>/PKGBUILD.xsh` and export:

- `name: Str`, `ver: Str`, and positive `rel: Str`;
- `package_kind: "payload" | "meta"`;
- `deps`, `mkdeps_host`, and optional `mkdeps_target` and `runtime_only_deps`;
- `upstream_sources` and `filetree`;
- `build(dest: Path)` for payload packages.

`deps` and `mkdeps_*` are build inputs: each is installed into the build root
with its runtime closure, and its artifact key enters the dependent's key.
`deps` are also runtime dependencies. `runtime_only_deps` are packages a
runtime root needs but no build uses (the `xsh` runner of an XSH script,
`xinit` for a service module, a font named by default config): they are never
installed into a build root (the dependent's or, transitively, its
dependents'), never order a build, and never enter an artifact key, so
rebuilding one rebuilds none of its dependents. A package may appear in only
one of `deps`, `mkdeps_*`, and `runtime_only_deps`; one the build uses belongs
in `deps`. A build tool's own runtime needs stay `deps` when dependents run it
at build time (`flex` needs `m4`), except `xsh`, which the executor substrate
seeds into every build root.

Payload recipes also carry `proof.xsh`. Metapackages declare no payload
`filetree`; they may contain dependencies only. `filetree` is the exact output
contract: each file or symlink is explicit, while a `tree` declaration covers
ordinary descendants. ELF outputs must be declared as `binary`.

Recipe loading is quarantined in `pm/recipe.xsh`. The rest of PM receives only
typed `Package` values; runtime lifecycle hooks are not part of the package
contract. Immutable root preflight rejects ownership conflicts before any
generation is written.

Recipe hooks take one `Path` and return `Result[Unit]`. `pm/recipe_hooks.xsh`
validates `build` and optional `prepare` against the existing declared capability
sets: `[fs, error]`, `[fs, env, error]`, `[process, env, error]`, or
`[fs, process, env, error]`. Optional `prepare_sources` uses `[fs, error]`.
Module validation compares declared effects exactly, so the boundary retains
each recipe's capabilities. A missing optional hook remains a no-op; a present
hook with incompatible parameters, result, export kind, or capabilities is
rejected before invocation.

`upstream_sources` selects `auto`, `archive`, `zip`, `cpio`, `file`, or
`directory` materialization. A URL source pins a sha256 per architecture; a
`SKIP` checksum is accepted only for a relative repository-local source. Source
strings may name the whole-word placeholders `VERSION`, `RELEASE`, `MAJOR`,
`MINOR`, `PATCH`, `IDENT`, `PACKAGE`, `ARCH`, `GOARCH`, and their
`TARGET_`/`BUILD_` forms (`pm/util.xsh::expand_source`); a word that merely
contains one, such as `PATCHES`, is left alone. Source preparation is part of
the package build identity. A `repository/` source is hashed after the same
expansion and only for the targets it selects, so `repository/.out/seed/ARCH`
keys each target's `xsh` by that target's seed alone. A recipe directory may
not hold a symlink that leaves it; shared PM code is imported through the
module path.

## Commands

```text
pm repo check [--repo PATH]
pm repo plan [--repo PATH] (--all | --root PACKAGE...) \
  [--target TARGET] --output PLAN
pm repo show PLAN
pm repo build PLAN --store STORE [-j N|--jobs N]
pm repo publish PLAN --store STORE
pm repo checksum [--repo PATH] PACKAGE...
pm repo update-checksums [--repo PATH] PACKAGE...
pm sources fetch [--repo PATH] (--all | PACKAGE...) [--target TARGET]...

pm root compose PLAN \
  --store STORE \
  --runtime-root PACKAGE... \
  --output GENERATION
pm root inspect GENERATION
pm store verify --store STORE
pm store extract PLAN --store STORE --package PACKAGE --path PATH --output FILE
```

`repo plan` is the only resolution boundary. It is offline unless
`XSH_PM_REPO` names a package repository (the local mirror, for example
`http://127.0.0.1:3000`, or a `file://` tree); there is no default remote. It records the target, typed
dependency graph, remote retrieval identity, build/proof inputs, `BUILD_EPOCH`,
action reasons, and sorted artifact keys in an atomically written
plan. `aarch64-linux-musl` remains the default build target.
`x86_64-linux-musl` can be planned and built on a native Linux x86_64 runner
with target-specific source checksums, filetrees, remote index entries, and
artifact keys. On other hosts, `repo build` rejects x86_64 before creating a
store. Artifact receipts can carry either
target and reject cross-target reuse of the same key. Root preflight and
composition preserve an explicit target and reject mixed receipts. Generation
plans and receipts also preserve x86_64 when supplied with verified x86_64
artifacts. The executor preserves x86_64 through recipe selection, build
metadata, proofs, receipts, and root composition.

`repo build` discovers the repository only by walking to a directory containing
both `pm.xsh` and `repo/`. It executes the saved plan with `pm/execute.xsh`;
artifact-store receipts are the sole resume state. `-j` changes scheduling only,
never a plan or artifact key.

`repo publish` selects the completed plan nodes from verified receipts, uploads
immutable payload, metadata, and proof objects, then updates the index last.
It publishes to `XSH_PM_REPO`. `file://` trees and the loopback local mirror
(`http://127.0.0.1[:PORT]`, `http://localhost[:PORT]`) need no token and are
sent none; any other remote needs `LAPUTA_TOKEN` from the process environment.
PM does not store credentials.

`root compose` selects only typed runtime and runtime-only edges from the saved
plan and writes an immutable generation receipt. It never installs into a live root. `root
inspect` and `store verify` are read-only receipt checks.
`store extract` copies one manifest-declared file from the exact artifact named
by a saved BuildPlan. `pm/generation_adapter.xsh::generation_adapter_copy_manifest_file`
checks the Store receipt and payload digest, verifies the file against artifact
metadata, and publishes the output by atomic rename. `PATH` must be canonical
and relative. Image builders use it for kernel files that are deliberately
absent from the runtime generation.
For a profile-owned overlay, `pm/generation.xsh::plan_profile` selects the
runtime closure and binds the overlay digest into its identity.
`write_generation_plan` and `read_generation_plan` persist and validate that
typed plan before `compose` uses it; the saved plan must match the BuildPlan and
overlay used for execution.

## Sources

URL sources are content-addressed. `pm sources fetch` (`make fetch`, with
`ARCH=x86_64` for the other target) is the only command that contacts upstream
hosts: it downloads every pinned URL source of the selected packages into
`LAPUTA_SOURCE_CACHE` (default `.cache/sources`) as `sha256/<hash>`, at most four
at a time with retries, verifies each digest before the entry appears, skips
entries already present, and fails after reporting every dead URL and checksum
mismatch. The local mirror serves the same layout at `/sources/sha256/<hash>`.

A build resolves a URL source from that cache, else from
`${LAPUTA_MIRROR}/sources/sha256/<hash>` (verified, then added to the cache),
else it fails and names the missing source. Builds locate the cache through
`LAPUTA_SOURCE_CACHE` or `XSH_PM_REPOSITORY_ROOT`. Artifact keys hash the
recipe's source string and checksum, never where the bytes came from.
`repo checksum` and `repo update-checksums` read upstream directly to compute new
pins and add those bytes to the cache.

## Catalog and graph

`pm/catalog.xsh` is the repository-wide typed catalog boundary. It rejects
duplicate package names and malformed recipes before resolution.
`pm/policy.xsh` contains the explicit aarch64 bootstrap exceptions, while
`pm/graph.xsh` resolves stable runtime, runtime-only, build-host, and
build-target edges. The graph never adds an implicit package-manager
dependency. Its sorted topological levels and typed edge kinds are persisted
in `BuildPlan`. A plan includes the runtime-only dependencies of its packages
(roots compose them), but runtime-only and bootstrap edges order no build, so
a runtime-only edge may close a cycle; plan format 3 records them as
`runtime-only` node dependencies.
The native Docker adapter passes `XSH_PM_BOOTSTRAP_LLVM_ROOT=/usr/lib/llvm23`
for `gnu-stubs`: its LLVM edge is a bootstrap seed, so the recipe must use the
preseeded compiler while the replacement LLVM package is built.

`pm/make.xsh::check_tasks` and `run_tasks` accept `List[MakeTask]`, preserving
the task schema from compiler helpers through scheduling and spawned process
handles. `pkg_config_flags` preserves `PkgConfigFlags` string lists through
compiler and linker flag assembly. `MakeTask.argv` retains the existing heterogeneous argument boundary:
paths and strings are passed as individual process arguments rather than shell
source. Completed-task stamps are published only after the entire graph succeeds;
a failed command cancels unfinished peers.

## Identity, store, and snapshots

`pm/fingerprint.xsh` hashes canonical sorted input lines: recipe/package
inputs and proof input. The plan digest and artifact/proof keys therefore
exclude mtimes, absolute checkout paths, and `.git` state. A proof-only change
changes the proof identity without rebuilding the payload.

An artifact key (`pm/plan.xsh::artifact_key_for`) hashes the target, the
package id, the recipe input digest (recipe files except `proof.xsh`, source
records and checksums, and `repository/` inputs), `pm/policy.xsh::BUILD_EPOCH`,
and the key of every direct `deps` and `mkdeps_*` dependency. Each of those is
installed into the build root with its runtime closure, because recipes link
against libraries they declare only in `deps`; each dependency key covers that
dependency's own closure. Runtime-only dependency keys are excluded, and Store
receipts omit them (one artifact serves every plan that pairs it with any
runtime-only artifact). The executor (XSH runners, PM tree,
core applets) is not a key input, so XSH and PM changes rebuild nothing. The
executor that built an artifact is recorded as provenance in its metadata
(`executor`) and receipt (`executor_sha256`). Bump `BUILD_EPOCH` to rebuild
every package after an executor change that alters payloads; bump a recipe's
`rel` to rebuild one package and its dependents. Executing a plan resolved at
another `BUILD_EPOCH` is rejected.

When a dependency is rebuilt, `repo plan` builds its dependents even if the
remote index already holds their tuple; publishing them under the same tuple
is the immutable-tuple conflict `repo publish` reports. A recipe tuple behind
the remote's is rejected, because publishing it would move the index back.

`pm/store.xsh` accepts only validated keys under `STORE/v2/`; older layouts
are never read. It locks a key, stages the payload, records the payload digest
computed once at staging plus metadata and proof hashes, writes the receipt
last, and atomically renames the final directory. Lookups trust those
commit-time hashes; `store verify` and `repo publish` re-hash every object.
Final artifacts are never overwritten. `pm/repo.xsh` publishes only verified
plan receipts and updates a file or remote snapshot index last. An index row's
`deps` are the recipe's `deps`; `runtime_only_deps` lists the rest of its
runtime set (rows without the field declare none).

`repo build` composes each build and proof root by extracting every dependency
payload once, directly into the root, after a metadata-only ownership check
(`pm/root.xsh::trusted_preflight`). A proof root holds the payload's `deps`
closure only: a runtime-only dependency may not be built yet when its
dependent is proved, so package proofs never check its files. Recipes see the build root as both
`LAPUTA_ROOT` and `XSH_PM_BUILD_ROOT`.

## Root composition

`pm/root.xsh` preflights the exact artifact inventories and ownership before it
mutates a generation root. `pm/generation.xsh` chooses direct runtime roots and
the runtime closure (runtime and runtime-only edges) only, then writes the deterministic receipt used by Laputa
to construct a disk image. Build tools do not leak into that closure unless a
separate typed runtime edge requires them.
Regular files and directories retain permission bits through `0o7777`,
including setuid helpers; symlink metadata remains fixed at `0o777`.

## Scope

PM builds aarch64 Linux-musl packages through the existing runner and x86_64
Linux-musl packages on a native Linux x86_64 runner. The shell-compatible
surface is limited to packages whose declared runtime capability requires it;
package construction itself uses typed XSH process and filesystem boundaries.

## Verification

PM behavior is covered by the focused modules under `tests/xsh/`:
`pm_recipe.xsh`, `pm_recipe_hooks.xsh`, `pm_graph.xsh`, `pm_graph_contracts.xsh`,
`pm_make.xsh`, `pm_plan.xsh`, `pm_store.xsh`,
`pm_root.xsh`, `pm_execute.xsh`, `pm_publish.xsh`, `pm_generation.xsh`, and
`pm_cli.xsh`.

The isolated `pm_graph_contracts.xsh` module covers nominal plan-action identity,
dependency-first ordering, selection boundaries, and cycle errors without
loading recipes or starting package builds. Run it against the checked-out
debug tools with `../xsh/target/debug/xsht test --jobs 1 tests/xsh/pm_graph_contracts.xsh`.
`pm_recipe_hooks.xsh` likewise exercises checked hook dispatch, absence, rejected
contracts, and cwd restoration with temporary fixtures. These host checks do not
validate Linux package execution. `pm_make.xsh`
uses temporary native child scripts to verify argument and environment preservation,
dependency order, stamp reuse, failed-peer cancellation, and checked pkg-config
flag lists without package builds. `ca_certificates_recipe.xsh` checks the proof
metadata boundary using a temporary bundle and helper; `m4_recipe.xsh` checks
literal source operands and rejection of directory inputs. `parser_generators.xsh`
checks Bison token definitions, Flex definition expansion, generated output paths,
and missing-input diagnostics independently of Linux build modules.

Run a host-native suite with `make test-native XSH_ROOT=$HOME/d/laputa-systems/xsh`.
`make test-pm-docker` runs the same suite on Linux with the local XSH seed
(`make seed`) inside the package-tools image, offline. There is no published
runner pin: the seed is always the current `XSH_ROOT` checkout.
