# Package Manager

`pm.xsh` is the typed Laputa package manager. It turns package recipes into a
deterministic `BuildPlan`, executes only that plan through immutable artifacts,
publishes verified snapshots, and composes runtime-only root generations.

## Package Contract

Recipes live at `packages/<package>/PKGBUILD.xsh` and export:

- `name: Str`, `ver: Str`, and positive `rel: Str`;
- `package_kind: "payload" | "meta"`;
- optional `architectures: List[Str]`, the targets (`aarch64`, `x86_64`) the
  package exists for;
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
at build time (`flex` and `bison` need `m4`), except `xsh`, which the executor
seeds into every build root.

A recipe without `architectures` exists for every target. One that names a
subset (CPU microcode for one vendor's x86 parts, say) is left out of the
catalog for any other target, so `--all` never plans it there, a `--root` on
it finds no recipe, and a package that depends on it fails to load for that
target. A per-source `architectures` list only selects that source's inputs.

A package that compiles against the kernel's userspace API headers takes
`linux-headers` as a build dependency, never `linux`. `linux-headers` installs
those headers from the pinned kernel tarball without a compiler, through an
XSH port of the kernel's `headers_install`. The parity tests live in
`packages/linux-headers/tests/`. `linux` ships only the kernel image and
config, so a kernel config or Kbuild change rebuilds only the kernel, and no
runtime root pulls in the kernel through a library.

Payload recipes also carry `proof.xsh`. Metapackages declare no payload
`filetree`; they may contain dependencies only. `filetree` is the exact output
contract: each file or symlink is explicit, while a `tree` declaration covers
ordinary descendants. ELF outputs must be declared as `binary`.

Recipe loading is quarantined in `pm/recipe.xsh`. The rest of PM receives only
typed `Package` values; runtime lifecycle hooks are not part of the package
contract.

Recipe hooks (`build`, optional `prepare` and `prepare_sources`) take one `Path`
and return `Result[Unit]`. `pm/recipe_hooks.xsh` lists the accepted effect sets,
compared exactly. A missing optional hook is a no-op; a present hook with an
incompatible signature or effects is rejected before invocation.

`upstream_sources` selects `auto`, `archive`, `zip`, `cpio`, `file`,
`directory`, or `cargo-vendor` materialization (see [Sources](#sources)). A URL source pins a sha256 per architecture; a
`SKIP` checksum is accepted only for a relative repository-local source. Source
strings may name whole-word placeholders such as `VERSION` and `ARCH`
(`pm/util.xsh::expand_source` lists them); a word that merely contains one, such
as `PATCHES`, is left alone. Source preparation is part of
the package build identity. A `repository/` source is hashed after the same
expansion and only for the targets it selects, so `repository/.out/seed/ARCH`
keys each target's `xsh` by that target's seed alone. A recipe directory may
not hold a symlink that leaves it; shared PM code is imported through the
module path.

## Commands

The command list and options are the help text in `pm.xsh` (`pm --help`).
Targets are `aarch64-linux-musl` and `x86_64-linux-musl`. `pm.xsh` declares the
typed command tree; `pm/cli.xsh` owns domain validation and execution and does
not parse argv. Missing or malformed arguments exit 2 with usage. Domain
selection errors keep `PmError.Usage` and exit 3. Empty commands and groups
print help and exit 0.

`--without PACKAGE` (with `--all` only) plans every package whose build
closure contains no excluded package, and records that set as the plan's
roots; `--all --without cmake --without linux` is the `STOP=pre-cmake`
selection of `make build`. `repo plan` is the only resolution boundary. It is
offline unless `XSH_PM_REPO` names a package repository (the local mirror, for
example `http://127.0.0.1:3000`, or a `file://` tree); there is no default
remote. It records the target, typed dependency graph, remote retrieval
identity, build/proof inputs, `BUILD_EPOCH`, action reasons, and sorted
artifact keys in an atomically written plan.

Without `--target`, `repo plan` and `sources fetch` use the host's arch; the
make targets and the profile CLI always pass the target for `ARCH` or the host
and run PM in package-tools on the host's native Docker platform.
`x86_64-linux-musl` is planned anywhere and built only on a native Linux x86_64
runner (`repo build` rejects it elsewhere before creating a store), with
target-specific source checksums, filetrees, remote index entries, and artifact
keys. Receipts carry one target and reject cross-target reuse of a key; root
preflight and composition reject mixed-target receipts.

`repo build` discovers the repository only by walking to a directory containing
both `pm.xsh` and `packages/`. It executes the saved plan with `pm/execute.xsh`;
artifact-store receipts are the sole resume state. `-j` changes scheduling only,
never a plan or artifact key.

`repo publish` selects the completed plan nodes from verified receipts, uploads
immutable payload, metadata, and proof objects, then updates the index last.
Objects are named by key and the index row is the only mutable pointer (see
"Publication" below). It publishes to `XSH_PM_REPO`, under the plan target's
arch. `file://` trees and the loopback local mirror
(`http://127.0.0.1[:PORT]`, `http://localhost[:PORT]`) need no token and are
sent none; any other remote needs `LAPUTA_TOKEN` from the process environment.
PM does not store credentials.

`root compose` selects only typed runtime and runtime-only edges from the saved
plan and writes an immutable generation receipt. It never installs into a live
root. `root inspect` and `store verify` are read-only receipt checks.

`store extract` copies one manifest-declared file from the exact artifact a saved
BuildPlan names (`pm/generation_adapter.xsh::generation_adapter_copy_manifest_file`
checks the receipt, payload digest, and artifact metadata, then publishes by
atomic rename). `PATH` must be canonical and relative. Image builders use it for
kernel files absent from the runtime generation.

For a profile-owned overlay, `pm/generation.xsh::plan_profile` selects the
runtime closure and binds the overlay digest into its identity. The saved
generation plan must match the BuildPlan and overlay used for execution.

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

A `cargo-vendor` source names a Cargo.lock (a pinned URL or a recipe file) and
a destination, `LOCK => vendor`. Its crates.io `[[package]]` records are a
content-addressed crate set: each record's `checksum` is the sha256 crates.io
serves `NAME-VERSION.crate` under, so the lockfile's own pin covers every
crate and the artifact key needs nothing more. `pm sources fetch` caches the
lockfile with the other URL sources, then reads it from the cache and fetches
each `.crate` from `static.crates.io` into the same `sha256/<hash>` layout. A
build resolves every crate like any URL source before staging anything, then
extracts each into `DEST/NAME-VERSION/` with the `.cargo-checksum.json`
cargo's directory sources need, so a recipe builds with `--offline --locked`
and `source.crates-io.replace-with` naming a directory source at `DEST`.
Records without `source` (workspace and path packages) are skipped; any other
non-crates.io record is rejected, because it has no content address. The
destination may not be the source root.

## Catalog and graph

`pm/catalog.xsh` is the repository-wide typed catalog boundary. It rejects
duplicate package names and malformed recipes before resolution.
`pm/policy.xsh` holds the explicit bootstrap exceptions (the same seed rules
for both targets); `pm/graph.xsh` resolves runtime, runtime-only, build-host, and
build-target edges and adds no implicit package-manager dependency. Sorted
topological levels and typed edge kinds are persisted in `BuildPlan`. A plan includes the runtime-only dependencies of its packages
(roots compose them), but runtime-only and bootstrap edges order no build, so
a runtime-only edge may close a cycle; plan format 3 records them as
`runtime-only` node dependencies. A bootstrap edge names a build input a seed
substitutes, so it selects no package either: planning `musl` does not pull in
`zlib`, and through it `cmake`.
The Docker adapter (`system/docker.xsh`) passes
`XSH_PM_BOOTSTRAP_LLVM_ROOT=/usr/lib/llvm23` for `gnu-stubs`: its LLVM edge is a
bootstrap seed, so the recipe uses the preseeded compiler while the replacement
LLVM package is built.

[Make task graphs](MAKE.md) covers the typed build helpers and scheduler.

## Identity, store, and snapshots

`pm/fingerprint.xsh` hashes canonical sorted input lines: recipe/package
inputs and proof input. The plan digest and artifact/proof keys therefore
exclude mtimes, absolute checkout paths, and `.git` state. A proof-only change
changes the proof identity without rebuilding the payload.

Checkout entries (recipe trees and `repository/` and directory sources) are
hashed and staged in git's mode model (`pm/util.xsh::checkout_mode`): 0755
for directories and executable files, 0644 for other files, and symlinks by
target alone. Mode bits beyond the executable bit, such as the umask's group
write or a setgid inherited from a parent directory, are host noise, so the
same checkout gets the same keys and payload modes on every host.

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
remote index already holds their tuple, and when the remote row's artifact key
differs from the local one it builds rather than reuses. A recipe tuple behind
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
`LAPUTA_ROOT` and `XSH_PM_BUILD_ROOT`, with its `bin` and `usr/bin` first on
`PATH`, and `CC=cc` and `CXX=c++`, so tools that score every compiler they find
(muon) take the build root's.

Before a package's own proof runs, PM checks every ELF file it installs: a
`DT_NEEDED` name another package in the proof root provides must come from the
package's runtime closure, and no `DT_NEEDED` entry may be a path, which only
a link against a SONAME-less library by its build-time path produces.

### Publication

Package identity is the artifact key; `ver`-`rel` is for display and ordering.
Because keys exclude the executor, a new seed, a PM edit, or a rebuilt
dependency rebuilds a package under the same `ver`-`rel`. Remote objects are
therefore content-addressed (`pm/util.xsh::remote_binary_rel`,
`remote_metadata_rel`, `remote_proof_rel`):

```text
packages/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>.tar.gz
metadata/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>-<proof12>.json
proofs/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>-<proof12>.json
```

`<artifact12>` and `<proof12>` are the first twelve hex digits of the artifact
and proof keys; the index row carries both in full. Metadata and proof also
name the proof key because a proof-only change re-proves the same payload.
Objects are uploaded with `If-None-Match: *` and never replaced; an existing
object is accepted only when its bytes match, so a retried publication
completes. `<arch>` and the index row's `arch` come from the plan target.

`pm/repo.xsh::repo_merge_publication` treats the index row (one per arch and
name) as the only mutable pointer:

- an identical row is already published;
- a row whose `ver`-`rel` is behind the remote's is refused (`make publish`
  plans offline, so this is where it meets the remote);
- otherwise the row is replaced, which publishes a rebuild under the same
  `ver`-`rel` (a new key) or a newer release. Earlier objects stay published.

The same keys with different bytes (another store's non-reproducible payload)
fail at the object upload. Root composition and generations follow artifact
keys, not `ver`-`rel`: a rebuilt package yields a new generation digest and a
new system bundle key. Rows published before content-addressed names point at
legacy `<name>-<ver>-<rel>` objects; they stay readable, and republishing the
artifact moves the row to content-addressed names.

## Root composition

`pm/root.xsh` preflights exact artifact inventories and ownership before it
mutates a generation root, so ownership conflicts are rejected before any
generation is written. `pm/generation.xsh` chooses direct runtime roots and the
runtime closure (runtime and runtime-only edges), then writes the deterministic
receipt Laputa uses to construct a disk image. Build tools do not enter the
closure unless a typed runtime edge requires them. Regular files and
directories keep permission bits through `0o7777`, including setuid helpers;
symlink metadata stays `0o777`.

## Verification

PM behavior is covered by the modules under `tests/pm/`; `tests/pm/fixtures/`
holds staged inputs. Run the module for the contract you are changing, for
example `$XSHT test --jobs 1 tests/pm/pm_graph_contracts.xsh`. Suites and wider
runs are in [Testing](TESTING.md). The seed is always the current `XSH_ROOT`
checkout; there is no published runner pin.

## Recipe authoring

Package construction must not depend on `/bin/sh`, `/usr/bin/sh`, or `SHELL`,
including generated Ninja rules. Use XSH `cd` blocks, structured `run` argv,
direct tool entrypoints, or `#!/bin/xsh` wrappers. Inputs under
`files/generated/` or package-local `files/*.c` replace heavyweight generators;
document their regeneration path beside them.

The `xsh` recipe exposes only the core applets declared in its `filetree`. Add
command links only when Laputa needs them, and keep `su` outside `/usr/bin`.
