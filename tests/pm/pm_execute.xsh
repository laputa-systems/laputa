##! Behavior coverage for immutable BuildPlan execution through isolated artifact roots.
use pm.catalog
use pm.execute
use pm.fingerprint
use pm.generation
use pm.local
use pm.plan
use pm.plan_json
use pm.policy
use pm.store
use pm.types

pure fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/{name}"
}

pure empty_remote_snapshot() -> types.RemoteSnapshot {
  {target: types.Aarch64LinuxMusl, index_sha256: "execute-empty-remote", packages: []}
}

proc copied_execute_repository(ctx: TestContext, name: Str) [fs, env, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name:)?
  let _ = fs.copy_tree(fixture("execute/packages"), fp"{root}/packages", parents: true, overwrite: true)?
  fs.mkdir(fp"{root}/pm")?
  fs.copy(p"pm/proof.xsh", fp"{root}/pm/proof.xsh", overwrite: true)?
  root
}

proc resolve_execute_plan_for_roots(repo_root: Path, roots: List[Str]) [fs, env, error] -> Result[types.BuildPlan] {
  let value = catalog.load(repo_root)?
  plan.resolve(value, empty_remote_snapshot(), policy.aarch64_docker(), roots, false)?
}

proc resolve_execute_plan(repo_root: Path) [fs, env, error] -> Result[types.BuildPlan] {
  resolve_execute_plan_for_roots(repo_root, ["execute-app"])?
}

proc node_named(value: types.BuildPlan, name: Str) [error] -> Result[types.PlanNode] {
  for node in value.nodes {
    return node when node.name == name
  }

  Err(types.PmError.PackageContract(f"missing execute plan node {name}"))
}

proc receipt_named(value: types.BuildResult, name: Str) [error] -> Result[types.ArtifactReceipt] {
  for receipt in value.artifacts {
    return receipt when receipt.package_name == name
  }

  Err(types.PmError.PackageContract(f"missing execute result artifact {name}"))
}

proc execute_store(ctx: TestContext, name: Str) [fs, error] -> Result[Path] {
  test.temp_dir(ctx, name:)
}

proc write_execute_metapackage(repo_root: Path) [fs, error] {
  let package = fp"{repo_root}/packages/execute-meta"
  fs.mkdir(package)?
  fs.write(
    fp"{package}/PKGBUILD.xsh",
    """##! Executor metapackage fixture without a payload proof.
## Package name.
export let name = "execute-meta"
## Metadata-only package kind.
export let package_kind = "meta"
## Package version.
export let ver = "1.0.0"
## Package release.
export let rel = "1"
## Runtime dependency.
export let deps = ["execute-dep"]
## No build-host dependencies.
export let mkdeps_host = []
## No build-target dependencies.
export let mkdeps_target = []
## No upstream source inputs.
export let upstream_sources = []
## No payload files.
export let filetree = []
""",
  )?
}

proc write_execute_leaf(repo_root: Path) [fs, error] {
  let package = fp"{repo_root}/packages/execute-leaf"
  fs.mkdir(package)?
  fs.write(
    fp"{package}/PKGBUILD.xsh",
    r"""##! Executor fixture that must not start until execute-app publishes.
## Package name.
export let name = "execute-leaf"
## Payload kind.
export let package_kind = "payload"
## Package version.
export let ver = "1.0.0"
## Package release.
export let rel = "1"
## Published dependency.
export let deps = ["execute-app"]
## No build-host dependencies.
export let mkdeps_host = []
## No build-target dependencies.
export let mkdeps_target = []
## No upstream source inputs.
export let upstream_sources = []
## Declared output.
export let filetree = [{path: p"usr/share/execute-leaf.txt", kind: "file"}]

## Builds only after the application payload is available.
export proc build(dest: Path) [fs, env, error] -> Result[Unit] {
  let root = env("LAPUTA_ROOT")?
  let _ = fs.read_text(fp"{root}/usr/share/execute-app.txt")?
  let target = fp"{dest}/usr/share/execute-leaf.txt"
  fs.mkdir(target.parent)?
  fs.write(target, "leaf\\n")?
}
""",
  )?
  fp"{package}/proof.xsh".write(r"""
error ProofError = MissingPayload

proc main(root: Path = /rootfs) [fs, error] {
  if ! fs.exists(fp"{root}/usr/share/execute-leaf.txt")? {
    return Err(ProofError.MissingPayload)
  }
}

main(@args)?
""")?
}

# `execute-service` runtime-only depends on `execute-dep`; its build fails if
# that dependency's payload reached its build root.
proc write_execute_service(repo_root: Path) [fs, error] {
  let package = fp"{repo_root}/packages/execute-service"
  fs.mkdir(package)?
  fs.write(
    fp"{package}/PKGBUILD.xsh",
    r"""##! Executor fixture with a runtime-only dependency.
## Package name.
export let name = "execute-service"
## Payload kind.
export let package_kind = "payload"
## Package version.
export let ver = "1.0.0"
## Package release.
export let rel = "1"
## No build-root dependencies.
export let deps = []
## Installed only by root composition.
export let runtime_only_deps = ["execute-dep"]
## No build-host dependencies.
export let mkdeps_host = []
## No upstream source inputs.
export let upstream_sources = []
## Declared output.
export let filetree = [{path: p"usr/share/execute-service.txt", kind: "file"}]

error ServiceBuildError = Failed(message: Str)

## Builds only when the runtime-only dependency is absent from the build root
## and the environment names the compilers PATH resolves in it.
export proc build(dest: Path) [fs, env, error] -> Result[Unit] {
  let root = env("LAPUTA_ROOT")?
  if fs.exists(fp"{root}/usr/share/execute-dep.txt")? {
    return Err(ServiceBuildError.Failed("execute-dep reached the build root"))
  }
  if env("CC")? != "cc" or env("CXX")? != "c++" {
    return Err(ServiceBuildError.Failed("the build environment does not name the compilers"))
  }
  let target = fp"{dest}/usr/share/execute-service.txt"
  fs.mkdir(target.parent)?
  fs.write(target, "service\n")?
}
""",
  )?
  fp"{package}/proof.xsh".write(r"""
error ProofError = Failed(message: Str)

proc main(root: Path = /rootfs) [fs, error] {
  if ! fs.exists(fp"{root}/usr/share/execute-service.txt")? {
    return Err(ProofError.Failed("missing execute-service payload"))
  }
}

main(@args)?
""")?
}

proc exact_remote_snapshot(
  value: types.BuildPlan,
  result: types.BuildResult,
  remote_root: Path,
) [fs, error] -> Result[types.RemoteSnapshot] {
  var packages: List[types.RemotePlanArtifact] = []

  for node in value.nodes {
    let receipt = receipt_named(result, node.name)?
    let executor_sha256 = receipt.executor_sha256
    let tarball = fp"{remote_root}/packages/aarch64/{node.name}/{node.package_id}.tar.gz"
    let metadata = fp"{remote_root}/metadata/aarch64/{node.name}/{node.package_id}.json"
    fs.mkdir(tarball.parent)?
    fs.mkdir(metadata.parent)?
    fs.copy(fp"{receipt.artifact_dir}/payload.tar.gz", tarball, overwrite: true)?
    let raw = json.read(fp"{receipt.artifact_dir}/metadata.json")?.require(local.PackageMetadataDto)?
    fs.write(metadata, json.encode({...raw, executor_sha256})? + "\n")?
    packages = packages.push({
      name: node.name,
      ver: node.ver,
      rel: node.rel,
      retrieval: {
        arch: "aarch64",
        tarball: tarball.relative_to(remote_root).display(),
        tarball_sha256: hash.sha256(tarball)?.hex(),
        metadata: metadata.relative_to(remote_root).display(),
        metadata_sha256: hash.sha256(metadata)?.hex(),
      },
      artifact_key: node.artifact_key,
      recipe_sha256: node.recipe_sha256,
      executor_sha256,
      proof_key: node.proof_key,
      proof_sha256: node.proof_sha256,
    })
  }

  {target: value.target, index_sha256: "execute-remote-snapshot", packages}
}

test test_execute_metadata_wire_schema_preserves_extensions_and_rejects_invalid_file_modes [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "execute-metadata-wire")?
  let metadata = fp"{root}/metadata.json"
  let pkg: types.Package = types.Package(
    dir: root,
    name: "wire-package",
    ver: "1.0.0",
    rel: "1",
    kind: types.Payload,
    deps: ["runtime-dependency"],
    runtime_only_deps: [],
    mkdeps_host: [],
    mkdeps_target: [],
    upstream_sources: [],
    filetree: [{path: p"usr/share/wire-package", kind: types.File}],
    nostrip: false,
    source_mirror: false,
    architectures: ["aarch64", "x86_64"],
  )
  let payload_hash = bytes.from_text("payload").sha256().hex()
  let built: types.BuiltPackage = types.BuiltPackage(
    pkg:,
    id: "wire-package-1.0.0-1",
    tarball: fp"{root}/payload.tar.gz",
    manifest: [p"usr/share/wire-package"],
    etcsums: [],
    metadata_sha256: payload_hash,
    metadata_files: [{path: "usr/share/wire-package", kind: types.File, mode: 0o644, sha256: payload_hash, target: ""}],
  )
  let executor: types.ExecutorProvenance = types.ExecutorProvenance(
    format: "laputa-executor-provenance-1",
    xsh_sha256: payload_hash,
    xshi_sha256: payload_hash,
    xsht_sha256: payload_hash,
    pm_sha256: payload_hash,
    core_sha256: null,
  )
  local.write_package_metadata(metadata, "x86_64", built, executor)?
  let recorded = json.read(metadata)?.require(Record)?.get("executor")?.require(types.ExecutorProvenance)?
  assert recorded == executor
  let wire = json.read(metadata)?.require(local.PackageMetadataDto)?
  assert wire.arch == "x86_64"
  assert wire.package_kind == "payload"
  assert wire.filetree[0].kind == "file"
  assert wire.files[0].kind == "file"
  assert wire.files[0].mode == 0o644
  assert wire.manifest == ["usr/share/wire-package"]

  json.write(metadata, {...wire, future_package_metadata: "retained"})?
  let extended = json.read(metadata)?.require(local.PackageMetadataDto)?
  json.write(metadata, {...extended, executor_sha256: payload_hash})?
  let forwarded = json.read(metadata)?.require(Record)?
  let extension: Str = forwarded.get("future_package_metadata")?.require()?
  let executor_hash: Str = forwarded.get("executor_sha256")?.require()?
  assert extension == "retained"
  assert executor_hash == payload_hash

  json.write(metadata, {...extended, files: [{...extended.files[0], mode: "invalid"}]})?
  match json.read(metadata)?.require(local.PackageMetadataDto) {
    Ok(_) => test.fail("metadata schema accepted a string file mode")?
    Err(_) => {}
  }
}

test test_execute_builds_dependency_levels_in_isolated_roots_and_reuses [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-build-repo")?
  let value = resolve_execute_plan(repo_root)?
  let object_store = execute_store(ctx, "execute-build-store")?
  let stale = fp"{object_store}/v2/tmp/{node_named(value, "execute-app")?.artifact_key}"
  fs.mkdir(stale)?
  fs.write(fp"{stale}/partial", "interrupted build state")?
  let first = execute.build_plan(value, repo_root, object_store, "", 2)?
  assert [node.name for node in value.nodes] == ["execute-dep", "execute-tool", "execute-app"]
  assert [receipt.package_name for receipt in first.artifacts] == ["execute-dep", "execute-tool", "execute-app"]
  assert [receipt.origin for receipt in first.artifacts] == [types.Built, types.Built, types.Built]
  assert fs.exists(store.artifact_path(object_store, node_named(value, "execute-app")?.artifact_key))?
  assert fs.exists(stale)? == false
  assert fs.exists(fp"{repo_root}/packages/execute-app/run-package-build.xsh")? == false

  # Jobs are a scheduler choice, never a build-plan or artifact-key input.
  let second = execute.build_plan(value, repo_root, object_store, "", 3)?
  assert second == first
}

test test_execute_x86_64_plan_preserves_target_and_metadata [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-x86-repo")?
  let pkgbuild = fp"{repo_root}/packages/execute-dep/PKGBUILD.xsh"
  fs.write(
    pkgbuild,
    pkgbuild.read_text()?.replace(
      "export let filetree = [{path: p\"usr/share/execute-dep.txt\", kind: \"file\"}]",
      "export let filetree = []\n## Target-specific declared output.\nexport let filetree_x86_64 = [{path: p\"usr/share/execute-dep.txt\", kind: \"file\"}]",
    ),
  )?
  let proof = fp"{repo_root}/packages/execute-app/proof.xsh"
  fs.write(
    proof,
    proof.read_text()?.replace(
      "proc main(root: Path = /rootfs) [fs, error] {",
      "proc main(root: Path = /rootfs) [fs, env, error] {\n  if env(\"XSH_PM_TARGET_ARCH\")? != \"x86_64\" {\n    return Err(ProofError.Failed(\"proof ran under the wrong target\"))\n  }",
    ),
  )?
  let value = plan.resolve(
    catalog.load_for_target(repo_root, types.target_x86_64())?,
    {target: types.target_x86_64(), index_sha256: "execute-empty-x86-remote", packages: []},
    policy.x86_64_docker(),
    ["execute-app"],
    false,
  )?
  let object_store = execute_store(ctx, "execute-x86-store")?
  let result = execute.build_plan(value, repo_root, object_store, "", 2)?

  for receipt in result.artifacts {
    assert receipt.target == types.target_x86_64()
    let metadata = json.read(fp"{receipt.artifact_dir}/metadata.json")?.require(local.PackageMetadataDto)?
    assert metadata.arch == "x86_64"
  }

  assert [receipt.package_name for receipt in result.artifacts] == ["execute-dep", "execute-tool", "execute-app"]
}

test test_execute_reproofs_changed_proof_without_rebuilding_payload [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-reproof-repo")?
  let object_store = execute_store(ctx, "execute-reproof-store")?
  let initial = resolve_execute_plan(repo_root)?
  let built = execute.build_plan(initial, repo_root, object_store, "", 1)?
  let initial_app = node_named(initial, "execute-app")?
  let initial_receipt = receipt_named(built, "execute-app")?
  let proof_path = fp"{repo_root}/packages/execute-app/proof.xsh"
  fs.write(proof_path, proof_path.read_text()? + "\n# proof revision only\n")?
  let reproved_plan = resolve_execute_plan(repo_root)?
  let reproved_app = node_named(reproved_plan, "execute-app")?
  assert reproved_app.artifact_key == initial_app.artifact_key
  assert reproved_app.proof_key == initial_app.proof_key == false
  let reproved = execute.build_plan(reproved_plan, repo_root, object_store, "", 2)?
  assert receipt_named(reproved, "execute-app")? == initial_receipt
  assert fs.exists(store.reproof_receipt_path(object_store, reproved_app.artifact_key, reproved_app.proof_key))?
}

test test_execute_parallel_level_requires_published_dependency_receipts [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-level-barrier-repo")?
  write_execute_leaf(repo_root)?
  let object_store = execute_store(ctx, "execute-level-barrier-store")?
  let app_proof = fp"{repo_root}/packages/execute-app/proof.xsh"
  fs.write(
    app_proof,
    """error ProofError = Failed(message: Str)

proc main(root: Path) [error] {
  return Err(ProofError.Failed("intentional level-one proof failure"))
}

main(@args)?
""",
  )?
  let value = resolve_execute_plan_for_roots(repo_root, ["execute-leaf"])?
  let app = node_named(value, "execute-app")?
  let leaf = node_named(value, "execute-leaf")?
  assert app.level == 1
  assert leaf.level == 2
  assert [dependency.name for dependency in leaf.dependencies] == ["execute-app"]

  # Level zero has independent dep/tool work under two workers. The level-one
  # proof then fails. A dependent level must never run and replace that cause
  # with an absent-artifact error.
  match execute.build_plan(value, repo_root, object_store, "", 2) {
    Ok(_) => test.fail("parallel executor advanced past a failed dependency level")?
    Err(problem) => assert "package proof for execute-app" in problem.message
  }

  assert fs.exists(store.artifact_path(object_store, app.artifact_key))? == false
  assert fs.exists(store.artifact_path(object_store, leaf.artifact_key))? == false
}

test test_execute_rebuilds_changed_recipe_and_dependents [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-package-change-repo")?
  let object_store = execute_store(ctx, "execute-package-change-store")?
  let initial = resolve_execute_plan(repo_root)?
  let _ = execute.build_plan(initial, repo_root, object_store, "", 1)?
  let initial_dep = node_named(initial, "execute-dep")?
  let initial_app = node_named(initial, "execute-app")?
  let pkgbuild = fp"{repo_root}/packages/execute-dep/PKGBUILD.xsh"
  fs.write(pkgbuild, pkgbuild.read_text()?.replace("dependency\\n", "dependency revision two\\n"))?
  let changed = resolve_execute_plan(repo_root)?
  let changed_dep = node_named(changed, "execute-dep")?
  let changed_app = node_named(changed, "execute-app")?
  assert changed_dep.artifact_key == initial_dep.artifact_key == false
  assert changed_app.artifact_key == initial_app.artifact_key == false
  let result = execute.build_plan(changed, repo_root, object_store, "", 1)?
  assert receipt_named(result, "execute-dep")?.key == changed_dep.artifact_key
  assert fs.exists(store.artifact_path(object_store, changed_app.artifact_key))?
  assert receipt_named(result, "execute-app")?.key == changed_app.artifact_key
}

test test_execute_rebuilds_when_package_source_input_changes [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-source-change-repo")?
  let object_store = execute_store(ctx, "execute-source-change-store")?
  let initial = resolve_execute_plan(repo_root)?
  let _ = execute.build_plan(initial, repo_root, object_store, "", 1)?
  let initial_app = node_named(initial, "execute-app")?
  fs.write(fp"{repo_root}/packages/execute-app/files/input.txt", "source revision two\n")?
  let changed = resolve_execute_plan(repo_root)?
  let changed_app = node_named(changed, "execute-app")?
  assert changed_app.artifact_key == initial_app.artifact_key == false
  let result = execute.build_plan(changed, repo_root, object_store, "", 1)?
  assert receipt_named(result, "execute-app")?.key == changed_app.artifact_key
}

test test_execute_metapackage_keeps_opaque_marker_and_proves_runtime_dependencies [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-meta-repo")?
  write_execute_metapackage(repo_root)?
  let value = resolve_execute_plan_for_roots(repo_root, ["execute-meta"])?
  assert [node.name for node in value.nodes] == ["execute-dep", "execute-meta"]
  let object_store = execute_store(ctx, "execute-meta-store")?
  let result = execute.build_plan(value, repo_root, object_store, "", 1)?
  let dependency = receipt_named(result, "execute-dep")?
  let meta = receipt_named(result, "execute-meta")?
  let meta_metadata = json.read(fp"{meta.artifact_dir}/metadata.json")?.require(local.PackageMetadataDto)?
  let files = meta_metadata.files

  # No meta proof script exists. Success therefore proves the executor did not
  # attempt to extract or run the opaque marker, while its runtime dependency
  # still completed the regular proof path first.
  assert fs.read_text(fp"{meta.artifact_dir}/payload.tar.gz")? == "laputa metapackage payload marker\n"
  assert meta_metadata.package_kind == "meta"
  test.eq(files, [])?
  assert fs.exists(fp"{meta.artifact_dir}/proof.json")?
  assert fs.exists(fp"{dependency.artifact_dir}/proof.json")?
}

test test_execute_imports_exact_remote_artifacts_without_remote_index_resolution [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-remote-repo")?
  let local_plan = resolve_execute_plan(repo_root)?
  let local_store = execute_store(ctx, "execute-remote-local-store")?
  let local_result = execute.build_plan(local_plan, repo_root, local_store, "", 1)?
  let remote_root = test.temp_dir(ctx, name: "execute-remote-objects")?
  let snapshot = exact_remote_snapshot(local_plan, local_result, remote_root)?
  let catalog_value = catalog.load(repo_root)?
  let remote_plan = plan.resolve(catalog_value, snapshot, policy.aarch64_docker(), ["execute-app"], false)?
  assert [types.plan_action_text(node.action) for node in remote_plan.nodes] == [
    "reuse-remote",
    "reuse-remote",
    "reuse-remote",
  ]

  let imported_store = execute_store(ctx, "execute-remote-imported-store")?
  let imported = execute.build_plan(remote_plan, repo_root, imported_store, f"file://{remote_root}", 1)?
  assert [receipt.origin for receipt in imported.artifacts] == [types.Remote, types.Remote, types.Remote]
  assert [receipt.key for receipt in imported.artifacts] == [node.artifact_key for node in remote_plan.nodes]
}

test test_execute_proof_failure_and_corrupt_final_never_publish_replacement [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-proof-failure-repo")?
  let object_store = execute_store(ctx, "execute-proof-failure-store")?
  let proof_path = fp"{repo_root}/packages/execute-app/proof.xsh"
  fs.write(
    proof_path,
    """error ProofError = Failed(message: Str)

proc main(root: Path = /rootfs) [error] {
  return Err(ProofError.Failed(\"intentional proof failure\"))
}

main(@args)?
""",
  )?
  let failed_plan = resolve_execute_plan(repo_root)?
  let failed_app = node_named(failed_plan, "execute-app")?

  match execute.build_plan(failed_plan, repo_root, object_store, "", 1) {
    Ok(_) => test.fail("failed proof unexpectedly published an application artifact")?
    Err(problem) => assert "package proof for execute-app" in problem.message
  }

  assert fs.exists(store.artifact_path(object_store, failed_app.artifact_key))? == false

  let healthy_repo = copied_execute_repository(ctx, "execute-corrupt-repo")?
  let healthy_plan = resolve_execute_plan(healthy_repo)?
  let healthy_store = execute_store(ctx, "execute-corrupt-store")?
  let healthy = execute.build_plan(healthy_plan, healthy_repo, healthy_store, "", 1)?
  let healthy_app = node_named(healthy_plan, "execute-app")?
  let final_dir = store.artifact_path(healthy_store, healthy_app.artifact_key)
  fs.write(fp"{final_dir}/payload.tar.gz", "corrupt final payload")?

  # Reuse trusts commit-time hashes and never overwrites a final artifact;
  # explicit Store verification is what detects the corruption.
  let reused = execute.build_plan(healthy_plan, healthy_repo, healthy_store, "", 1)?
  assert reused == healthy
  assert fs.read_text(fp"{final_dir}/payload.tar.gz")? == "corrupt final payload"

  match store.verify_artifact(healthy_store, healthy_app.artifact_key) {
    Ok(_) => test.fail("corrupt final artifact unexpectedly verified")?
    Err(problem) => assert "payload SHA-256 does not match receipt" in problem.message
  }
}

test test_execute_records_executor_provenance_outside_artifact_keys [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-provenance-repo")?
  let value = resolve_execute_plan(repo_root)?
  let result = execute.build_plan(value, repo_root, execute_store(ctx, "execute-provenance-store")?, "", 1)?

  for receipt in result.artifacts {
    let executor = json.read(fp"{receipt.artifact_dir}/metadata.json")?.require(Record)?.get("executor")?.require(types.ExecutorProvenance)?
    assert executor.format == "laputa-executor-provenance-1"
    assert receipt.executor_sha256 == fingerprint.executor_provenance_sha256(executor)?
  }
}

test test_execute_rejects_plan_from_another_build_epoch [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-epoch-repo")?
  let other_epoch = {...policy.aarch64_docker(), build_epoch: policy.BUILD_EPOCH + 1}
  let value = plan.resolve(catalog.load(repo_root)?, empty_remote_snapshot(), other_epoch, ["execute-app"], false)?
  let object_store = execute_store(ctx, "execute-epoch-store")?

  match execute.build_plan(value, repo_root, object_store, "", 1) {
    Ok(_) => test.fail("plan from another BUILD_EPOCH unexpectedly executed")?
    Err(problem) => assert f"resolved at BUILD_EPOCH {policy.BUILD_EPOCH + 1}" in problem.message
  }

  assert fs.exists(fp"{object_store}/v2")? == false
}

type TraceSpanDto = {file: Str}

type TraceEventDto = {kind: Str, name: Str?, source_span: TraceSpanDto?}

# Counts `hash.sha256` calls per PM module in a JSONL trace.
proc sha256_calls_by_module(trace: Path) [fs, error] -> Result[Map[Int]] {
  var counts: Map[Int] = {}

  for line in fs.read_text(trace)?.split("\n") {
    continue when line.trim() == ""
    let event = json.decode(line)?.require(TraceEventDto)?
    continue unless event.kind == "module.call" and event.name == "hash.sha256"
    let span = event.source_span
    let module_name = if span == null { "unknown" } else { fp"{span.file}".name }
    counts[module_name] = (counts.get(module_name) ?? 0) + 1
  }

  counts
}

# Each built payload is hashed exactly once (when staged); the Store hashes
# only the small metadata and proof objects it records, and a rebuild that
# reuses every artifact hashes nothing at all.
test test_execute_hashes_each_payload_once_and_reuse_hashes_nothing [fs, process, env, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-hash-count-repo")?
  let object_store = execute_store(ctx, "execute-hash-count-store")?
  let plan_path = test.temp_path(ctx, name: "execute-hash-count-plan.json")
  plan_json.write_plan(plan_path, resolve_execute_plan(repo_root)?)?
  let source = r"""use pm.execute
use pm.plan_json

proc main(plan_path: Path, repo_root: Path, object_store: Path) [fs, net, process, env, time, error] {
  let _ = execute.build_plan(plan_json.read(plan_path)?, repo_root, object_store, "", 1)?
}

main(@args)?
"""
  let modules = path.absolute(p".")?
  var runs: List[Map[Int]] = []

  for name in ["fresh", "reuse"] {
    let trace = test.temp_path(ctx, name: f"execute-hash-count-{name}.jsonl")
    let outcome = test.run_xsht_trace(
      ctx,
      source,
      ["--raw", "--trace-format", "jsonl", "--trace-file", trace.display()],
      [plan_path.display(), repo_root.display(), object_store.display()],
      {XSH_MODULE_PATH: modules.display()},
    )?
    assert outcome.success
    runs = runs.push(sha256_calls_by_module(trace)?)
  }

  let fresh = runs[0]
  assert (fresh.get("execute.xsh") ?? 0) == 3
  assert (fresh.get("store.xsh") ?? 0) == 6
  assert (fresh.get("proof.xsh") ?? 0) == 0
  assert (fresh.get("root.xsh") ?? 0) == 0

  let reuse = runs[1]
  test.eq(reuse.keys() |> sort, [])?
}

test test_execute_keeps_runtime_only_dependency_out_of_build_root_and_composes_it [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-runtime-only-repo")?
  write_execute_service(repo_root)?
  let value = resolve_execute_plan_for_roots(repo_root, ["execute-service"])?
  # Both nodes share level 0, and execute-dep builds first: only the missing
  # build-root edge keeps its payload out of execute-service's build root.
  assert [node.name for node in value.nodes] == ["execute-dep", "execute-service"]
  assert [node.level for node in value.nodes] == [0, 0]

  let object_store = execute_store(ctx, "execute-runtime-only-store")?
  let result = execute.build_plan(value, repo_root, object_store, "", 1)?
  let service = receipt_named(result, "execute-service")?
  test.eq(service.dependency_keys, [])?
  test.eq(service.runtime_dependency_keys, [])?

  let overlay = fp"{test.temp_dir(ctx, name: "execute-runtime-only-overlay")?}/overlay"
  fs.mkdir(overlay)?
  let generation_plan = generation.plan(value, ["execute-service"], generation.overlay_digest(overlay)?)?
  assert [artifact.package_name for artifact in generation_plan.artifacts] == ["execute-dep", "execute-service"]
  let output = fp"{test.temp_dir(ctx, name: "execute-runtime-only-generation")?}/root"
  let receipt = generation.compose(generation_plan, object_store, output, overlay)?
  assert fp"{output}/usr/share/execute-dep.txt".read_text()? == "dependency\n"
  assert fp"{output}/usr/share/execute-service.txt".read_text()? == "service\n"
  generation.verify_generation(output, receipt)?
}

# Parallel builds each write their own log, and a failure names its package
# and log instead of surfacing only a scheduler error.
test test_execute_parallel_builds_log_per_package_and_failures_name_their_log [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-logs-repo")?
  let value = resolve_execute_plan(repo_root)?
  let logs = test.temp_dir(ctx, name: "execute-logs")?
  let _ = execute.build_plan(value, repo_root, execute_store(ctx, "execute-logs-store")?, "", 2, logs)?

  for name in ["execute-dep", "execute-tool", "execute-app"] {
    assert fs.exists(fp"{logs}/{name}.log")?, f"{name} has a log"
  }

  fs.write(
    fp"{repo_root}/packages/execute-app/proof.xsh",
    """error ProofError = Failed(message: Str)

proc main(root: Path) [error] {
  return Err(ProofError.Failed("intentional proof failure"))
}

main(@args)?
""",
  )?
  let failing = resolve_execute_plan(repo_root)?
  let failed_logs = test.temp_dir(ctx, name: "execute-failed-logs")?

  match execute.build_plan(failing, repo_root, execute_store(ctx, "execute-failed-store")?, "", 2, failed_logs) {
    Ok(_) => test.fail("a failing proof built")?
    Err(problem) => {
      assert f"{failed_logs}/execute-app.log" in problem.message, problem.message
      assert "intentional proof failure" in problem.message, problem.message
    }
  }
}
