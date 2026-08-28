# Laputa Core Simplification and Finalization

You are completing the Laputa infrastructure migration across:

```text
~/d/laputa-systems/packages
~/d/laputa-systems/laputa
~/d/laputa-systems/xsh
~/d/laputa-systems/xinit
```

The large architectural migration is already substantially implemented. Do **not** redesign the system from scratch and do not mechanically implement the old `laputa/plan.md`.

This is the final design direction.

**Simplification takes precedence over literal parity with the old plan.**

The goal is a small, rigorous system whose correctness comes from:

* typed package metadata;
* one dependency graph;
* deterministic build planning;
* content-addressed package artifacts;
* exact source checksums;
* isolated build roots;
* package proofs that actually execute;
* runtime-only system composition;
* atomic publication;
* a real QEMU/dwl/foot end-to-end proof.

Do **not** build a provenance, attestation, derivation, or receipt framework around those operations.

At the time this follow-up was written, the reviewed remote heads were approximately:

```text
packages 50e4056541732b2e2fb3642374194755dcb67d2a
laputa   5f5170ebce4cfc60c73f80890bc295de8f914cb5
```

The local checkouts are authoritative and may be newer.

Do not reset, discard, overwrite, or stash user changes.

---

# 1. Final conceptual model

The system should converge on roughly four meaningful durable concepts:

```text
BuildPlan
StoredArtifact
GenerationManifest
SystemProfile
```

Everything else must justify its existence.

The complete pipeline is:

```text
PKGBUILD.xsh
    ↓
typed Package
    ↓
PackageCatalog
    ↓
typed dependency graph
    ↓
BuildPlan
    ↓
build/reuse artifact
    ↓
RUN CURRENT PACKAGE PROOF
    ↓
StoredArtifact
    ↓
runtime closure + SystemProfile overlay
    ↓
GenerationManifest + immutable generation
    ↓
kernel + ext4 + GPT image
    ↓
atomic system bundle
    ↓
real QEMU dwl + foot proof
```

The proof executions are critical.

Proof **receipts and attestations are not**.

---

# 2. Non-negotiable simplification rules

Apply these rules throughout the implementation.

## Keep

Keep these because they buy real correctness:

* typed `PackageKind`;
* typed `DependencyKind`;
* typed source/file kinds where multiple real cases exist;
* `PackageCatalog`;
* one graph implementation;
* deterministic `BuildPlan`;
* package recipe semantic hashes;
* artifact keys derived from exact dependency artifact keys;
* exact upstream source checksums;
* isolated per-package build roots;
* immutable content-addressed package artifacts;
* preflight path/file ownership checks;
* runtime-only dependency closure;
* atomic directory publication;
* repository objects immutable before index switch;
* package proofs;
* ELF runtime-dependency checking;
* one typed `qemu-dwl-foot` profile;
* native `linux/arm64` Docker execution;
* actual QEMU + HVF + dwl + foot + QMP keyboard proof.

## Delete

Delete these concepts entirely unless some concrete external compatibility boundary absolutely requires a tiny decoder:

```text
ProofReceipt
proof_key
proof attestation
proof cache
proof object stored beside artifact
published remote proof object
proof_receipt_sha256
ArtifactOrigin as durable state
ArtifactReceipt as a second metadata model
RootPlan
RootReceipt
GenerationPlan + GenerationReceipt as separate concepts
ExecutorIdentity
PM-tree fingerprint
XSH runner fingerprint in artifact keys
core-tree fingerprint in artifact keys
repository-wide digest in BuildPlan
remote-index digest in BuildPlan
fake one-valued Target unions
fake Unsupported/Reserved union tags
legacy world state
legacy online install DB inside package payloads
legacy etcsums machinery
legacy package install/remove semantics
generation_adapter.xsh workaround if process boundaries can replace it
ProfileBuildRequestDto if process boundaries can replace it
```

If deleting one of these exposes a simpler design, prefer the simpler design.

---

# 3. Scope

The new core infrastructure supports exactly:

```text
development host: macOS Apple Silicon
package/build execution: native linux/arm64 Docker
package/system architecture: aarch64
system profile: qemu-dwl-foot
runtime acceptance: qemu-system-aarch64 + HVF + dwl + foot
```

Explicitly outside scope:

```text
x86-64 core builds
native cross compilation
binfmt package execution
real hardware
browsers
audio
Tailscale
Wi-Fi
live package activation
rollback UI
artifact garbage collection
distributed builds
Nix-style derivation semantics
supply-chain attestations
cryptographic signing
reproducible-build certification
```

Existing dormant x86-64 checksum/filetree metadata inside individual recipes may remain if removing it is pointless churn.

Do not maintain x86-64 core PM, Docker, bootstrap, test, or CI flows.

Installer tooling is separate. Do not redesign the installer during this work.

---

# 4. Start by reading and verifying local state

Read:

```bash
cat ~/d/laputa-systems/xsh/AGENTS.md
cat ~/d/laputa-systems/xsh/docs/IDIOMS.md

cat ~/d/laputa-systems/packages/AGENTS.md
cat ~/d/laputa-systems/packages/PM.md
cat ~/d/laputa-systems/packages/LAPUTA.md

cat ~/d/laputa-systems/laputa/AGENTS.md
cat ~/d/laputa-systems/laputa/plan.md
cat ~/d/laputa-systems/laputa/docs/DEVELOPMENT.md
cat ~/d/laputa-systems/laputa/docs/QEMU.md
```

Record:

```bash
git -C ~/d/laputa-systems/packages status --short
git -C ~/d/laputa-systems/laputa status --short

git -C ~/d/laputa-systems/packages rev-parse HEAD
git -C ~/d/laputa-systems/laputa rev-parse HEAD
```

Preserve unrelated changes.

Before major edits, run the current focused tests so actual regressions can be distinguished from pre-existing failures.

---

# 5. Final package data model

The current `pm/types.xsh` is over-modelled.

Simplify it.

The important package-side types should look approximately like:

```xsh
type PackageKind =
  Payload |
  Meta

type DependencyKind =
  Runtime |
  BuildHost |
  BuildTarget |
  Bootstrap

type SourceKind =
  Auto |
  Archive |
  Zip |
  Cpio |
  SourceFile |
  Directory |
  Git

type FileKind =
  File |
  Binary |
  Symlink |
  Tree

type PlanAction =
  Build(reason: Str) |
  ReuseRemote(reason: Str)

type Package = {
  dir: Path,
  name: Str,
  ver: Str,
  rel: Str,
  kind: PackageKind,
  deps: List[Str],
  mkdeps_host: List[Str],
  mkdeps_target: List[Str],
  upstream_sources: List[UpstreamSource],
  filetree: List[FileTreeEntry],
  nostrip: Bool,
  source_mirror: Bool,
}

type PlanDependency = {
  name: Str,
  kind: DependencyKind,
  artifact_key: Str,
}

type RemoteArtifact = {
  payload: Str,
  payload_sha256: Str,
  metadata: Str,
  metadata_sha256: Str,
}

type PlanNode = {
  name: Str,
  ver: Str,
  rel: Str,
  package_id: Str,
  recipe_dir: Path,
  recipe_sha256: Str,
  artifact_key: Str,
  action: PlanAction,
  level: Int,
  dependencies: List[PlanDependency],
  remote: RemoteArtifact?,
}

type BuildPlan = {
  format: Str,
  build_epoch: Int,
  roots: List[Str],
  nodes: List[PlanNode],
  plan_sha256: Str,
}

type StoredArtifact = {
  key: Str,
  package_name: Str,
  package_id: Str,
  payload: Path,
  metadata: Path,
}
```

Exact names may vary slightly to fit current XSH conventions.

The important point is what is **not** present.

Remove:

```text
Target
ExecutorIdentity
ArtifactOrigin
ArtifactReceipt
proof_key
proof_sha256
proof receipt fields
repository_digest
remote_index_sha256
runtime_dependency_keys duplicated into artifact metadata
```

Aarch64 is simply the architecture of this PM generation.

At external JSON/repository boundaries use:

```text
"aarch64"
```

where needed.

Do not invent fake union variants merely to satisfy a type-system minimum-variant rule.

---

# 6. Introduce one explicit BUILD_EPOCH

Replace exact PM/XSH executor fingerprinting with a deliberate build-contract epoch.

Put it somewhere obvious and durable, e.g.:

```xsh
export let BUILD_EPOCH = 1
```

in an appropriate focused PM module.

The artifact key should approximately be:

```text
SHA256(
    artifact-format-version
    BUILD_EPOCH
    package ID
    semantic package recipe hash
    dependency kind/name/artifact-key tuples
)
```

Do not include:

```text
PM source-tree hash
xsh binary hash
xshi binary hash
xsht binary hash
core applet tree hash
jobs
timestamps
checkout path
remote URL
remote index hash
unrelated package recipes
proof script
```

Document `BUILD_EPOCH` clearly:

> Increment this only when PM/XSH build semantics change in a way that can make unchanged package inputs produce semantically different artifacts.

This is an explicit engineering decision, not an automatically inferred provenance graph.

Add tests proving:

```text
recipe edit -> artifact key changes
dependency artifact key edit -> dependent key changes
proof.xsh edit -> artifact key unchanged
jobs edit -> unchanged
absolute checkout location -> unchanged
unrelated package edit -> unchanged
PM implementation edit -> unchanged until BUILD_EPOCH changes
BUILD_EPOCH change -> all affected artifact keys change
```

---

# 7. Simplify BuildPlan identity

The current BuildPlan contains too much ambient repository state.

Remove:

```text
repository_digest
remote_index_sha256
executor identity
proof identity
target
```

The plan is complete when it contains:

```text
selected roots
build epoch
exact selected package nodes
exact dependency edges
exact artifact keys
exact remote retrieval paths/hashes where reuse is selected
canonical plan digest
```

An edit to an unrelated package must not change the plan for:

```text
--root foot-minimal
```

unless that package enters its selected closure.

Publishing an unrelated remote package must not change the BuildPlan digest.

The exact remote payload and metadata hashes carried by reused nodes are sufficient to make execution independent from subsequent index changes.

Execution must never re-resolve a remote index.

---

# 8. Delete the entire proof receipt/attestation system

Package proofs remain mandatory.

Everything that persists proof provenance goes away.

Delete:

```text
proof_key
proof-input identity in BuildPlan
proof receipts
proof JSON stored in artifact directories
/artifacts/v1/proofs/
proof caches
proof cache locks
remote proof object paths
remote proof receipt hashes
remote proof validation
published proof metadata
ArtifactReceipt.proof_*
```

The package build lifecycle becomes:

```text
resolve BuildPlan
↓
for node:
    build or import exact artifact
    compose exact runtime proof root
    run CURRENT proof.xsh
↓
success
```

## Warm builds

A warm `pm repo build` should:

```text
not rebuild exact artifacts
still run current proofs
```

This is intentional.

Proofs should be fast relative to compilation.

Do not optimize this away with a proof cache.

If proof execution becomes expensive in the future, solve that based on actual profiling rather than adding provenance machinery now.

## Proof changes

Changing only:

```text
repo/foo/proof.xsh
```

must:

```text
not change BuildPlan
not change artifact key
not rebuild foo
run the changed proof on the existing exact artifact
```

Add a fixture proof that writes to a temporary observable path or otherwise proves the proof actually executed on both cold and warm build invocations.

## Remote reuse

A remote artifact is trusted as **artifact bytes**, not as proof history.

For a `ReuseRemote` node:

1. fetch exact payload;
2. verify payload hash;
3. fetch exact metadata;
4. verify metadata hash;
5. validate metadata/package tuple;
6. atomically import artifact into local store;
7. construct proof runtime root;
8. run the current local `proof.xsh`.

No remote proof object is needed.

There must be no code that fabricates evidence that a remote proof occurred.

---

# 9. Simplify the package artifact store

Use a fresh store generation rather than preserving the current receipt-heavy layout.

Prefer:

```text
STORE/
└── v2/
    ├── sha256/
    │   └── <artifact-key>/
    │       ├── payload.tar.gz
    │       └── metadata.json
    ├── locks/
    │   └── <artifact-key>.lock
    └── tmp/
        └── <artifact-key>/
```

No `artifact.json`.

The final directory name is the semantic artifact identity.

Completeness means:

```text
directory exists
payload exists
metadata exists
both verify
metadata matches artifact key's expected BuildPlan node
```

## Commit protocol

Keep the strong existing behavior:

1. acquire artifact-key lock;
2. verify existing final artifact if present;
3. remove stale temporary directory;
4. stage payload + metadata into temp directory;
5. verify staged payload against metadata;
6. atomically rename temp directory to final key;
7. re-open and verify final;
8. release lock.

Never overwrite a valid final artifact.

If a final artifact is corrupt, fail.

Do not silently rebuild over corruption.

## Stored metadata

`metadata.json` should describe the package artifact itself, not PM history.

Keep roughly:

```json
{
  "format": "laputa-package-2",
  "name": "foo",
  "ver": "1.2.3",
  "rel": "4",
  "package_kind": "payload",
  "files": [
    {
      "path": "usr/bin/foo",
      "kind": "binary",
      "mode": 493,
      "sha256": "...",
      "target": ""
    }
  ]
}
```

For symlinks:

```json
{
  "path": "bin/foo",
  "kind": "symlink",
  "mode": 511,
  "sha256": "",
  "target": "../usr/bin/foo"
}
```

For directories:

```json
{
  "path": "var/tmp",
  "kind": "tree",
  "mode": 1023,
  "sha256": "",
  "target": ""
}
```

Do not duplicate:

```text
dependency graph
build origin
executor digest
proof state
repository state
```

inside package artifact metadata.

Those belong elsewhere or are operationally irrelevant.

---

# 10. Preserve full Linux modes

Fix root/artifact metadata to preserve:

```text
0000 .. 07777
```

not merely `0777`.

The current package set already needs setuid.

Add focused coverage for:

```text
0644
0755
04755
02755
01777
```

Verification and root composition must compare/preserve special bits.

Use the actual `sudo-rs` package as an integration regression if practical:

```text
/usr/bin/sudo -> 04755
/usr/bin/su   -> 04755
```

---

# 11. Remove the old mutable installed-package database from artifacts

The new immutable generation architecture does not need to emulate the old package installer.

Stop putting this into package payloads:

```text
var/lib/xsh-pm/packages/<name>/metadata.json
var/lib/xsh-pm/packages/<name>/manifest.json
var/lib/xsh-pm/packages/<name>/etcsums.json
```

Remove:

```text
etcsums
.new configuration merge behavior
extract_install
stored recipe directory paths
old install/remove lifecycle semantics
legacy mutable package DB reconstruction
```

Package payloads should contain package payload.

Package sidecar metadata should contain package inventory.

Generation state should be represented once by:

```text
/var/lib/laputa/generation.json
```

Migrate package proofs or ELF helpers that currently expect the installed package DB so they consume:

```text
BuildPlan dependency information
artifact metadata
explicit package/runtime closure
```

instead.

This should allow `pm/local.xsh` and `pm/root.xsh` to shrink substantially.

Delete functions that become unused.

---

# 12. Reset internal repository compatibility where it simplifies the code

This is pre-stable infrastructure.

Do not preserve complex compatibility merely because an experimental old mirror format exists.

Prefer a clean current format.

A new repository index row should contain only information needed to discover an exact artifact:

```json
{
  "name": "foot-minimal",
  "ver": "1.27.0",
  "rel": "11",
  "arch": "aarch64",
  "artifact_key": "...",
  "payload": "packages/aarch64/foot-minimal/foot-minimal-1.27.0-11.tar.gz",
  "payload_sha256": "...",
  "metadata": "metadata/aarch64/foot-minimal/foot-minimal-1.27.0-11.json",
  "metadata_sha256": "..."
}
```

Do not duplicate package dependency metadata in the index when the local package recipe is authoritative for graph resolution.

Do not include:

```text
proof key
proof hash
proof path
proof receipt
executor hash
source provenance receipt
```

If current remote compatibility is temporarily necessary to bootstrap the transition:

* isolate it in one narrow decoder;
* migrate/rebuild the aarch64 mirror;
* delete the compatibility decoder before completing this task.

Do not leave both repository formats permanently.

Use `file://` repositories for all destructive/migration tests.

Do not silently rewrite a live public mirror unless the normal repository credentials are available and doing so is part of the established deployment workflow.

The resulting codebase, however, should have one current repository model.

---

# 13. Keep source caching, but decouple it from artifact identity

Source availability is valuable.

Source provenance machinery is not required.

Use the existing source logic to create a simple verified cache.

Prefer something conceptually like:

```text
SOURCES/
└── sha256/
    └── <declared-source-sha256>
```

or retain an existing similarly simple source-cache layout if it is already good.

Rules:

* declared checksums remain authoritative;
* cached bytes are verified before use;
* cache location does not affect artifact identity;
* cache timestamps do not matter;
* deleting the artifact store does not require re-downloading cached source bytes.

Wire the existing Laputa source volume into actual PM execution:

```text
laputa-sources-aarch64-v2
```

Do not mount a source volume that the executor ignores.

## Source mirrors

Keep mirroring as a repository concern rather than an artifact concern.

A simple command is sufficient:

```text
pm repo mirror-sources PLAN --source-cache CACHE
```

or an equivalently small existing command.

For packages with:

```text
source_mirror = true
```

it should:

1. verify cached source bytes;
2. publish immutable source object(s);
3. be idempotent for identical remote bytes.

Do not put source objects or source receipts inside package artifact directories.

If retaining the existing remote source-mirror path convention is simpler, keep it.

---

# 14. Keep publication simple and retry-safe

`pm repo publish` should:

1. read and verify BuildPlan;
2. load each exact StoredArtifact;
3. run the current package proof again;
4. stage index updates;
5. upload immutable payload/metadata objects;
6. switch `index.json` last.

Running proofs during both:

```text
pm repo build
pm repo publish
```

is deliberate.

Publication should be a strong gate.

There is no durable proof receipt after it succeeds.

## Immutable object retry

For network publication:

* use create-only upload;
* if object already exists, fetch/hash it;
* identical bytes => success;
* different bytes => conflict.

This makes:

```text
objects uploaded
process crashes
index not switched
retry
```

safe and idempotent.

A package tuple with different bytes must fail.

The index remains the only mutable repository switch.

---

# 15. Collapse RootPlan/RootReceipt/GenerationPlan/GenerationReceipt

Replace them with one:

```xsh
type GenerationManifest = {
  format: Str,
  profile: Str,
  build_plan_sha256: Str,
  runtime_roots: List[Str],
  artifacts: List[GenerationArtifact],
  overlay_sha256: Str,
  generation_sha256: Str,
}
```

One object.

It is calculated before composition.

It is written into the final generation as:

```text
/var/lib/laputa/generation.json
```

The final file must equal the manifest that was used to compose it.

There is no separate receipt.

## Generation identity

Hash:

```text
format
profile name
BuildPlan digest
runtime roots
runtime artifact package names/IDs/keys
overlay digest
```

The runtime artifact closure follows **only Runtime edges**.

Do not include:

```text
BuildHost
BuildTarget
Bootstrap
```

unless a package is independently reachable by a Runtime edge.

## Composition

Implement:

```text
generation.manifest(...)
generation.compose(...)
generation.verify(...)
```

or similarly focused names.

Composition:

1. verify BuildPlan;
2. calculate exact runtime closure;
3. load and verify artifacts;
4. build complete path ownership map;
5. reject conflicts before mutation;
6. compose into `<generation>.tmp`;
7. apply explicit profile overlay;
8. verify every installed entry;
9. write `generation.json`;
10. atomically rename to final generation directory;
11. verify final generation.

Keep the existing good behavior where identical shared directory declarations coalesce.

Files and symlinks still have one owner.

---

# 16. Delete `generation_adapter.xsh` by using process boundaries

The current `generation_adapter.xsh` exists largely because PM and Laputa typed modules interact badly in one XSH process due to global user-module/tag identities.

Do not add more adapter DTO machinery.

Use the natural architecture boundary:

```text
Laputa process
    ↓ process.command_argv
PM process
```

Inside the native Linux container, Laputa should invoke the public PM program as child processes.

For example:

```text
/bin/xsh /src/packages/pm.xsh -- repo plan ...
/bin/xsh /src/packages/pm.xsh -- repo build ...
/bin/xsh /src/packages/pm.xsh -- generation manifest ...
/bin/xsh /src/packages/pm.xsh -- generation compose ...
```

Exact CLI spelling may be adjusted, but use public typed PM commands rather than importing PM's internal typed values into the Laputa process.

Delete if no longer necessary:

```text
pm/generation_adapter.xsh
ProfileBuildRequestDto
.build-request.json
primitive-only generation adapter types
comments/workarounds whose only purpose was PM/Laputa tag collisions
```

This process boundary should make the repository ownership split materially simpler.

---

# 17. Simplify the PM CLI

Keep one explicit, non-heuristic command parser.

A good final surface is approximately:

```text
pm repo check [--repo PATH]

pm repo plan [--repo PATH] \
  (--all | --root PACKAGE...) \
  --output PLAN

pm repo show PLAN

pm repo build PLAN \
  --store STORE \
  --source-cache CACHE \
  [-j N|--jobs N]

pm repo publish PLAN \
  --store STORE \
  [--repo PATH]

pm repo mirror-sources PLAN \
  --source-cache CACHE

pm repo checksum [--repo PATH] PACKAGE...
pm repo update-checksums [--repo PATH] PACKAGE...
pm repo source-audit [--repo PATH] PACKAGE...

pm generation manifest PLAN \
  --runtime-root PACKAGE... \
  --profile NAME \
  --overlay DIR \
  --output MANIFEST

pm generation compose PLAN \
  --manifest MANIFEST \
  --store STORE \
  --overlay DIR \
  --output ROOT

pm generation inspect MANIFEST_OR_ROOT

pm store verify --store STORE
```

Do not expose:

```text
--target
world-plan
install
remove
build-install
build-set
build-set-deps
build-upload-set
upload-set
upload-repo-export
auth
refresh-index
extension fallback
root/work/out positional guessing
package-path versus package-name guessing
```

A repository root may be discovered from cwd where unambiguous, with optional `--repo`.

Do not make every command repeat paths unnecessarily.

---

# 18. Simplify SystemProfile

Keep the typed profile, but make it describe only things that are genuinely data.

Prefer approximately:

```xsh
type QemuSpec = {
  machine: Str,
  cpu: Str,
  smp: Int,
  memory: Str,
  width: Int,
  height: Int,
}

type SystemProfile = {
  name: Str,
  package_roots: List[Str],
  kernel_package: Str,
  kernel_path: Path,
  qemu: QemuSpec,
  forbidden_packages: List[Str],
  forbidden_sonames: List[Str],
}
```

Delete:

```text
SystemTarget
UnsupportedSystemTarget
SessionSpec
DisplayMode if it merely derives from QemuMode
decorative interactive_argv
decorative proof_argv
decorative proof input data
```

The profile overlay is executable system policy.

Let it own:

```text
how mdevd is started
how seatd is started
how dwl is started
what foot runs
interactive boot behavior
proof boot behavior
```

Do not describe the same command both as typed profile data and XSH code.

The guest QEMU proof remains:

```text
guest/qemu-dwl-foot-proof.xsh
```

Host success/failure markers may be focused constants in `laputa/proof.xsh`.

There is only one profile today. Do not construct a generic framework for hypothetical future profiles.

---

# 19. Make package-tools self-bootstrapping

`laputa build qemu-dwl-foot` must work from a fresh local Docker state.

It must not assume this already exists:

```text
laputa-package-tools
```

Implement one focused boundary:

```xsh
docker.ensure_package_tools(...)
```

It should:

1. calculate a small package-tools input key;
2. check whether a matching arm64 image exists;
3. build it if absent/stale;
4. verify image architecture is `arm64`;
5. return the exact image tag.

The key should cover the actual bootstrap inputs:

```text
package-tools Dockerfile
bootstrap helper code
pinned XSH release
pinned XSH core release
PM bootstrap/build contract epoch
```

Do not include every package recipe if that would rebuild the bootstrap image after ordinary package edits.

## Simplify bootstrap Dockerfiles

The existing historical bootstrap pipeline contains many obsolete PM commands/stages.

Collapse it.

Prefer one focused:

```text
Dockerfile.package-tools
```

with roughly:

```text
pinned XSH + core
↓
explicit LLVM bootstrap seed
↓
minimum native build substrate
↓
current typed PM builds current build-essential-native closure
↓
final package-tools image
```

`bootstrap-llvm-seed.xsh` is a legitimate explicit bootstrap seam and may remain.

Delete obsolete staged bootstrap architecture, including old stages for packages that the normal BuildPlan can now build.

If possible delete:

```text
Dockerfile.bootstrap-build-essential-native
Dockerfile.build-essential-native
Dockerfile.linux
```

and replace them with the one current Dockerfile.

If a bootstrap-only Dockerfile is still genuinely required, keep exactly one and make its role narrow and documented.

Remove core amd64 branches.

Do not maintain an old bootstrap world merely because it once worked.

---

# 20. Build system bundles atomically

Do not publish:

```text
vmlinuz
rootfs.ext4
disk.img
```

individually into mutable fixed filenames.

Instead use:

```text
target/laputa/qemu-dwl-foot/
├── builds/
│   └── <system-key>/
│       ├── build-plan.json
│       ├── generation.json
│       ├── vmlinuz
│       ├── rootfs.ext4
│       └── disk.img
├── current -> builds/<system-key>
├── console.log
├── qemu.log
└── screenshot.ppm
```

No build receipt is required.

## System key

Calculate:

```text
SHA256(
    "laputa-qemu-system-1"
    generation_sha256
    kernel artifact key
    image format epoch
)
```

Add a tiny explicit image-format epoch only if image-building semantics need one.

Do not include host-only details that do not affect image bytes.

## Publication

Inside the Linux container:

1. compose generation;
2. extract exact kernel;
3. build ext4;
4. build GPT image;
5. verify all of them.

Then on the host output filesystem:

1. create `builds/<system-key>.tmp`;
2. copy all final objects;
3. hash-compare each source and destination;
4. verify generated files;
5. atomically rename the whole directory to `builds/<system-key>`;
6. atomically replace a temporary symlink with `current`.

Never overwrite a completed build directory.

No partially published build may become current.

The directory rename is the transaction.

No `build.json` receipt is necessary.

---

# 21. Make `laputa test` and `laputa boot` ensure current state

The final public CLI remains:

```text
laputa plan qemu-dwl-foot
laputa build qemu-dwl-foot [--jobs N]
laputa test qemu-dwl-foot [--jobs N]
laputa boot qemu-dwl-foot [--jobs N]
laputa clean qemu-dwl-foot
```

Allow `--jobs` on `test` and `boot` because they may need to ensure a build.

## `laputa build`

Must:

1. ensure package-tools image;
2. generate BuildPlan;
3. build/reuse artifacts;
4. run package proofs;
5. calculate GenerationManifest;
6. compose generation;
7. run forbidden package/SONAME checks;
8. extract kernel;
9. construct image;
10. publish/select atomic system bundle.

## `laputa test`

Must call the same ensure/build path first.

A warm test should generally involve:

```text
zero compilation
package proofs rerun
generation/system bundle reused if exact
QEMU test runs
```

Then:

1. resolve `current`;
2. use kernel and disk from that exact directory;
3. launch QEMU;
4. wait for proof-ready;
5. send `laputa` exactly once via QMP;
6. capture screenshot;
7. require `LAPUTA_DWL_FOOT_PROOF_OK`;
8. reject kernel panic/failure markers.

There must be no concept of “some disk.img already exists, so test it.”

## `laputa boot`

Also ensure current state first.

Then use the exact current bundle.

This prevents stale interactive boot behavior without introducing freshness metadata.

---

# 22. Keep QEMU proof concrete and simple

Preserve the good existing proof.

The acceptance system must still boot:

```text
Linux
xinit
profile boot hook
mdevd
seatd
dwl
foot
xsh reader
```

The host injects:

```text
laputa
```

through QMP only after:

```text
LAPUTA_DWL_FOOT_PROOF_READY
```

Guest confirms the actual foot child received it and emits:

```text
LAPUTA_DWL_FOOT_PROOF_OK
```

Host must fail on:

```text
Kernel panic
not syncing
Attempted to kill init
Insufficient stack space
LAPUTA_DWL_FOOT_PROOF_FAILED
```

Keep the focused Python QMP helper.

Do not rewrite it merely for language purity.

Do not reintroduce a shell supervisor.

---

# 23. Finish legacy code removal

Once the simplified path works, aggressively delete superseded code.

In `packages`, investigate and remove when unreferenced:

```text
proof receipt machinery
proof-cache machinery
ArtifactReceipt DTOs
ArtifactOrigin
ExecutorIdentity
Target fake unions
legacy remote artifact identity
legacy old-index decoders after repository reset
legacy package DB generation
legacy package DB reconstruction
etcsums
extract_install
old installed-package helpers
old mutable root/install helpers
runtime dependency keys duplicated into artifact receipts
generation adapter
RootPlan/RootReceipt
separate GenerationPlan/GenerationReceipt
old cross/native build-policy helpers
stale error variants
```

In `laputa`, investigate and remove when superseded:

```text
plan.md
export-remote-cache.xsh
Dockerfile.linux
historical bootstrap Dockerfile stages
obsolete bootstrap helper scripts
obsolete package-image preparation scripts
old bootstrap workflows
old x86 core workflows
stale fixed-output code
ProfileBuildRequestDto
.build-request.json transport
decorative SystemProfile session/proof fields
```

Do not remove installer-specific source merely because core no longer uses it.

---

# 24. Clean CI

Broken or obsolete workflow buttons are not acceptable.

## packages publish workflow

Make:

```text
packages/.github/workflows/laputa-package-publish.yml
```

aarch64-only.

Use current public commands:

```text
pm repo plan
pm repo build
pm repo publish
```

No:

```text
amd64
build-upload-set
old mutable repo staging
legacy command adapters
```

Use an explicit source cache and artifact store for the workflow.

## packages test workflow / Makefile

Make the primary PM suite native:

```text
linux/arm64
```

Remove the normal amd64 branch.

## laputa validation

Replace stale invocations of:

```text
pm list
boot.xsh
proof-stage.xsh
```

with current strict checks and profile planning.

A useful CI gate is:

```text
strict-check Laputa modules
run Laputa unit tests
ensure package-tools image/build logic works on arm64 Linux where applicable
generate qemu-dwl-foot BuildPlan
generate GenerationManifest
verify runtime closure excludes forbidden build dependencies
```

Do not claim GitHub Linux CI executes the macOS HVF QEMU acceptance test.

The authoritative complete acceptance remains local macOS.

## bootstrap workflows

Delete the old multi-artifact bootstrap chain if the self-contained package-tools Dockerfile supersedes it.

Prefer one current aarch64 package-tools/bootstrap workflow if CI coverage is desired.

No active workflow may invoke a deleted PM command.

---

# 25. Durable documentation

Create:

```text
laputa/docs/CORE-INFRASTRUCTURE.md
```

This should describe the current design, not the migration history.

Keep it concise.

Cover:

```text
repository ownership boundary
PackageCatalog and graph
BuildPlan
BUILD_EPOCH
StoredArtifact
package proof execution
source cache
repository publication
GenerationManifest
SystemProfile
package-tools bootstrap
atomic system bundles
QEMU acceptance
aarch64-only scope
```

Update:

```text
laputa/docs/DEVELOPMENT.md
laputa/docs/QEMU.md
laputa/AGENTS.md

packages/PM.md
packages/LAPUTA.md
packages/AGENTS.md
```

Delete:

```text
laputa/plan.md
```

Digest any remaining durable information before deleting it.

Do not leave milestone/planning documentation around after implementation.

---

# 26. Test requirements

Use TDD for each semantic change.

Do not preserve obsolete tests merely to keep line counts high.

The final tests should emphasize invariants.

## Recipe/catalog/graph

Keep tests for:

```text
invalid package metadata
duplicate deps
self-dependency
invalid paths
source checksum validation
runtime/build-host/build-target edge classification
bootstrap exceptions
cycle detection
runtime closure
build closure
deterministic ordering
```

## BuildPlan

Required:

```text
deterministic repeated plan
checkout-location independent
unrelated package edit does not affect selected plan
unrelated remote index change does not affect selected plan
recipe change changes artifact key
dependency key change propagates
proof edit does not change artifact key or BuildPlan
BUILD_EPOCH changes artifact key
jobs do not affect plan
exact remote payload carries exact retrieval hashes
execution never re-resolves index
```

## Store

Required:

```text
atomic first commit
warm exact reuse
stale temp ignored
corrupt final detected
payload/metadata mismatch detected
concurrent same-key commit safe
no artifact.json required
no proof object required
```

## Proof execution

Required:

```text
cold build runs proof
warm build runs proof again
remote reused artifact runs local proof
proof failure prevents successful build result
proof-only edit runs new proof without compilation
publish reruns proofs
```

Instrument fixtures so tests prove execution occurred.

## Root/generation

Required:

```text
runtime closure only
build-host excluded
build-target excluded
bootstrap excluded
shared identical directories coalesce
file conflict rejected before mutation
symlink traversal rejected
0644 preserved
0755 preserved
04755 preserved
02755 preserved
01777 preserved
overlay conflict rejected
generation manifest deterministic
failed composition leaves prior final untouched
```

## Source cache

Required:

```text
declared checksum verified
warm source cache avoids redownload
corrupt cache rejected/refetched safely
artifact deletion does not delete source cache
source mirror publication idempotent
```

## Repository

Required:

```text
payload/metadata immutable
index written last
identical existing remote object accepted
different existing object rejected
crash-after-object-upload retry succeeds
same tuple different content fails
```

## Laputa

Required:

```text
package-tools absent => build constructs it
wrong architecture image rejected
profile direct package roots exactly correct
generation excludes build tools
system bundle directory atomic
current changes only after full bundle succeeds
failed bundle leaves old current usable
test calls ensure/build first
boot calls ensure/build first
QEMU receives kernel/disk from same current directory
```

---

# 27. Final package runtime purity check

The direct runtime roots remain:

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

Kernel is separate:

```text
linux
```

At minimum these must not appear in the final generation merely because they built something:

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

Run ELF dependency auditing over the final generation.

Every dynamic dependency must be provided by the declared runtime closure.

---

# 28. Required static verification

Packages:

```bash
cd ~/d/laputa-systems/packages

~/d/laputa-systems/xsh/target/debug/xsht \
  check --strict \
  pm.xsh \
  pm/*.xsh \
  tests/xsh/*.xsh
```

Then:

```bash
make test
```

Laputa:

```bash
cd ~/d/laputa-systems/laputa

XSH_MODULE_PATH="$PWD:$HOME/d/laputa-systems/packages" \
~/d/laputa-systems/xsh/target/debug/xsht \
  check --strict \
  laputa.xsh \
  laputa/*.xsh \
  profiles/*.xsh \
  guest/*.xsh \
  tests/xsh/*.xsh
```

Run all focused Laputa tests.

---

# 29. Clean Docker-state acceptance test

This is mandatory.

The final core workflow must not depend on historical local Docker state.

Remove only the new package-tools image(s) and disposable new store/cache volumes.

Do not indiscriminately prune Docker.

Then:

```bash
cd ~/d/laputa-systems/laputa

"$HOME/d/laputa-systems/xsh/target/debug/xsh" \
  laputa.xsh -- build qemu-dwl-foot --jobs 4
```

Expected:

```text
package-tools bootstrap/ensure happens automatically
native linux/arm64 only
BuildPlan generated
artifacts built/imported
all package proofs run
GenerationManifest generated
runtime generation composed
kernel extracted
rootfs generated
GPT image generated
atomic system bundle selected as current
```

No undocumented preparation command may be necessary.

---

# 30. Warm-build acceptance

Run:

```bash
"$HOME/d/laputa-systems/xsh/target/debug/xsh" \
  laputa.xsh -- build qemu-dwl-foot --jobs 4
```

again.

Expected:

```text
same BuildPlan digest
same artifact keys
zero package recompilation
package proofs run again
source cache reused
same GenerationManifest digest
same system key
existing exact system bundle reused
```

This is the desired warm path.

Do not add proof caches to make it “warmer.”

---

# 31. Final one-command acceptance

The authoritative user-facing gate is:

```bash
cd ~/d/laputa-systems/laputa

"$HOME/d/laputa-systems/xsh/target/debug/xsh" \
  laputa.xsh -- test qemu-dwl-foot --jobs 4
```

It must first ensure current build state.

Then actual QEMU proof must succeed.

Required final line:

```text
laputa test qemu-dwl-foot: ok
```

Required guest marker:

```text
LAPUTA_DWL_FOOT_PROOF_OK
```

Required evidence:

```text
target/laputa/qemu-dwl-foot/current
target/laputa/qemu-dwl-foot/builds/<system-key>/generation.json
target/laputa/qemu-dwl-foot/builds/<system-key>/vmlinuz
target/laputa/qemu-dwl-foot/builds/<system-key>/rootfs.ext4
target/laputa/qemu-dwl-foot/builds/<system-key>/disk.img
target/laputa/qemu-dwl-foot/console.log
target/laputa/qemu-dwl-foot/qemu.log
target/laputa/qemu-dwl-foot/screenshot.ppm
```

Required absence:

```text
Kernel panic
not syncing
Attempted to kill init
Insufficient stack space
LAPUTA_DWL_FOOT_PROOF_FAILED
```

QMP must inject:

```text
laputa
```

exactly once after:

```text
LAPUTA_DWL_FOOT_PROOF_READY
```

and the guest must prove the actual foot child received it.

---

# 32. Final legacy search

Packages:

```bash
rg -n \
  'ProofReceipt|proof_key|proof_receipt|ArtifactReceipt|ArtifactOrigin|ExecutorIdentity|repository_digest|remote_index_sha256|RootReceipt|RootPlan|GenerationReceipt|generation_adapter|extract_install|etcsums|world-plan|build-set|build-install|build-upload-set|upload-set|\.world/state\.json|XSH_PM_NATIVE_CROSS|XSH_PM_HOOKS|LAPUTA_HOOK' \
  ~/d/laputa-systems/packages
```

Every remaining match must be either:

* an unavoidable external-format compatibility constant that is still current, or
* deleted.

Prefer deleting obsolete compatibility.

Laputa:

```bash
rg -n \
  'plan\.md|ProfileBuildRequestDto|\.build-request\.json|boot\.xsh|proof-stage\.xsh|Dockerfile\.linux|WORLD_TO_TRANCHE|WORLD_UPLOAD|XSH_BOOT_QEMU_AUDIO|XSH_BOOT_TAILSCALE|XSH_BOOT_QEMU_MESA|XSH_BOOT_QEMU_DEBUG|XSH_BOOT_ROOTFS_IMAGE|build-upload-set' \
  ~/d/laputa-systems/laputa
```

No active core implementation should match.

Installer-only matches may remain when clearly isolated.

---

# 33. Self-review before completion

Before declaring success, explicitly answer these questions from the resulting code:

1. Can I explain package correctness without mentioning a receipt?
2. Does every package proof actually execute on every build/publish invocation?
3. Can an unchanged artifact be reused without recompilation?
4. Does changing only a proof avoid compilation?
5. Can changing an unrelated package alter my selected BuildPlan?

   * It must not.
6. Can changing an unrelated remote index row alter my selected BuildPlan?

   * It must not.
7. Does a PM refactor rebuild the world automatically?

   * It must not unless `BUILD_EPOCH` is deliberately bumped.
8. Can a build-only dependency enter the final generation accidentally?

   * It must not.
9. Can the final root preserve `04755`?

   * It must.
10. Can a half-published kernel be paired with an old disk?

    * It must not.
11. Can `laputa test` unknowingly boot stale checkout state?

    * It must not.
12. Does a fresh Mac Docker state require a hidden bootstrap command?

    * It must not.
13. Is any field in `SystemProfile` decorative?

    * It must not.
14. Is any major type merely a duplicate representation of another durable object?

    * Remove it.
15. Is any remaining legacy code only present because an experimental old format once existed?

    * Prefer deleting it.

---

# 34. Completion report

At completion report:

```text
packages starting commit
packages ending commit
laputa starting commit
laputa ending commit

lines/modules deleted
legacy workflows deleted
final Store layout
BUILD_EPOCH value
final BuildPlan fields
final GenerationManifest fields
package-tools bootstrap strategy
source-cache strategy

cold build result
warm build result
whether warm build compiled anything
whether warm proofs reran
runtime-purity result

BuildPlan SHA256
Generation SHA256
system key
disk SHA256

QEMU result
screenshot path
console log path
qemu log path
```

Also state explicitly:

```text
proof receipts/attestations: removed
executor fingerprinting: removed
legacy world/install model: removed
separate root/generation receipts: removed
generation adapter: removed or explain precisely why impossible
aarch64-only core workflows: yes/no
fresh Docker-state build: pass/fail
one-command laputa test: pass/fail
```

Do not call the work complete with any core item above still failing.

The desired end state is not “maximum provenance.”

It is:

> **a small typed build system where exact inputs select immutable artifacts, proofs run for real, generations contain only runtime state, and one command can build and prove the actual Laputa desktop under QEMU.**
