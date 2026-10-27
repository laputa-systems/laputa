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
  fp"{root}/pm".mkdir()
  p"pm/proof.xsh".copy(to: fp"{root}/pm/proof.xsh", overwrite: true)
  root
}

proc resolve_execute_plan_for_roots(repo_root: Path, roots: List[Str]) -> Result[types.BuildPlan] {
  let value = catalog.load(repo_root)?
  plan.resolve(value, empty_remote_snapshot(), policy.aarch64_docker(), roots, false)?
}

proc resolve_execute_plan(repo_root: Path) -> Result[types.BuildPlan] {
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

proc execute_plan_output(
  ctx: TestContext,
  plan_path: Path,
  repo_root: Path,
  store_root: Path,
) [fs, process, env, error] {
  let source = r"""use pm.execute
use pm.plan_json

proc main(...args: List[Str]) [fs, net, process, env, time, error] {
  let _ = execute.build_plan(plan_json.read(fp"{args[0]}")?, fp"{args[1]}", fp"{args[2]}", "", 2)?
}

main(@args)?
"""
  let modules = path.absolute(p".")?
  test.run_xsh(ctx, source, [], [plan_path.display(), repo_root.display(), store_root.display()], {XSH_MODULE_PATH: modules})?
}

proc write_execute_metapackage(repo_root: Path) {
  let package = fp"{repo_root}/packages/execute-meta"
  package.mkdir()
  fp"{package}/PKGBUILD.xsh".write(
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
  )
}

proc write_execute_leaf(repo_root: Path) {
  let package = fp"{repo_root}/packages/execute-leaf"
  package.mkdir()
  fp"{package}/PKGBUILD.xsh".write(
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
export proc build(dest: Path) [fs, env, error] -> Result[Unit, Error] {
  let root = env("LAPUTA_ROOT")?
  let _ = fp"{root}/usr/share/execute-app.txt".read_text()?
  let target = fp"{dest}/usr/share/execute-leaf.txt"
  target.parent.mkdir()?
  target.write("leaf\\n")?
}
""",
  )
  fp"{package}/proof.xsh".write(r"""
error ProofError = MissingPayload

proc main(root: Path = /rootfs) [fs, error] {
  if ! fp"{root}/usr/share/execute-leaf.txt".exists()? {
    return Err(ProofError.MissingPayload)
  }
}

main(@args)?
""")
}

proc write_execute_service(repo_root: Path) {
  let package = fp"{repo_root}/packages/execute-service"
  package.mkdir()
  fp"{package}/PKGBUILD.xsh".write(
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
export proc build(dest: Path) [fs, env, error] -> Result[Unit, Error] {
  let root = env("LAPUTA_ROOT")?
  if fp"{root}/usr/share/execute-dep.txt".exists()? {
    return Err(ServiceBuildError.Failed("execute-dep reached the build root"))
  }
  if env("CC")? != "cc" or env("CXX")? != "c++" {
    return Err(ServiceBuildError.Failed("the build environment does not name the compilers"))
  }
  let target = fp"{dest}/usr/share/execute-service.txt"
  target.parent.mkdir()?
  target.write("service\n")?
}
""",
  )
  fp"{package}/proof.xsh".write(r"""
error ProofError = Failed(message: Str)

proc main(root: Path = /rootfs) [fs, error] {
  if ! fp"{root}/usr/share/execute-service.txt".exists()? {
    return Err(ProofError.Failed("missing execute-service payload"))
  }
}

main(@args)?
""")
}

proc exact_remote_snapshot(
  value: types.BuildPlan,
  result: types.BuildResult,
  remote_root: Path,
) -> Result[types.RemoteSnapshot] {
  var packages: List[types.RemotePlanArtifact] = []

  for node in value.nodes {
    let receipt = receipt_named(result, node.name)?
    let executor_sha256 = receipt.executor_sha256
    let tarball = fp"{remote_root}/packages/aarch64/{node.name}/{node.package_id}.tar.gz"
    let metadata = fp"{remote_root}/metadata/aarch64/{node.name}/{node.package_id}.json"
    tarball.parent.mkdir()
    metadata.parent.mkdir()
    fp"{receipt.artifact_dir}/payload.tar.gz".copy(to: tarball, overwrite: true)
    let raw = json.read(fp"{receipt.artifact_dir}/metadata.json")?.require(local.PackageMetadataDto)?
    metadata.write(json.encode({...raw, executor_sha256})? + "\n")
    packages += [
      {
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
      },
    ]
  }

  {target: value.target, index_sha256: "execute-remote-snapshot", packages}
}

proc executor_fixture_provenance(name: Str) [fs, error] -> Result[types.ExecutorProvenance] {
  let root = path.absolute(fixture(f"executor-validity/{name}"))?
  {
    format: "laputa-executor-provenance-1",
    xsh_sha256: bytes.from_text("xsh runner").sha256().hex(),
    xshi_sha256: bytes.from_text("xshi runner").sha256().hex(),
    xsht_sha256: bytes.from_text("xsht runner").sha256().hex(),
    pm_sha256: fingerprint.pm_tree(root)?,
    core_sha256: null,
  }
}

proc remote_snapshot_with_executor(
  value: types.RemoteSnapshot,
  remote_root: Path,
  executor: types.ExecutorProvenance,
) [fs, error] -> Result[types.RemoteSnapshot] {
  let executor_sha256 = fingerprint.executor_provenance_sha256(executor)?
  var packages: List[types.RemotePlanArtifact] = []

  for artifact in value.packages {
    let metadata = fp"{remote_root}/{artifact.retrieval.metadata}"
    let extended = json.read(metadata)?.require(local.PackageMetadataDto)?
    json.write(metadata, {...extended, executor, executor_sha256})
    packages += [
      {
        ...artifact,
        executor_sha256,
        retrieval: {...artifact.retrieval, metadata_sha256: hash.sha256(metadata)?.hex()},
      },
    ]
  }

  {...value, packages}
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
    proof_deps: [],
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
  local.write_package_metadata(metadata, "x86_64", built, executor)
  let recorded = json.read(metadata)?.require(Record)?.get("executor")?.require(types.ExecutorProvenance)?
  assert recorded == executor
  let wire = json.read(metadata)?.require(local.PackageMetadataDto)?
  assert wire.arch == "x86_64"
  assert wire.package_kind == "payload"
  assert wire.filetree[0].kind == "file"
  assert wire.files[0].kind == "file"
  assert wire.files[0].mode == 0o644
  assert wire.manifest == ["usr/share/wire-package"]

  json.write(metadata, {...wire, future_package_metadata: "retained"})
  let extended = json.read(metadata)?.require(local.PackageMetadataDto)?
  json.write(metadata, {...extended, executor_sha256: payload_hash})
  let forwarded = json.read(metadata)?.require(Record)?
  let extension: Str = forwarded.get("future_package_metadata")?.require()?
  let executor_hash: Str = forwarded.get("executor_sha256")?.require()?
  assert extension == "retained"
  assert executor_hash == payload_hash

  json.write(metadata, {...extended, files: [{...extended.files[0], mode: "invalid"}]})
  match json.read(metadata)?.require(local.PackageMetadataDto) {
    Ok(_) => test.fail("metadata schema accepted a string file mode")
    Err(_) => {}
  }
}

test test_execute_builds_dependency_levels_in_isolated_roots_and_reuses [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-build-repo")?
  let value = resolve_execute_plan(repo_root)?
  let object_store = execute_store(ctx, "execute-build-store")?
  let stale = fp"{object_store}/v2/tmp/{node_named(value, "execute-app")?.artifact_key}"
  stale.mkdir()
  fp"{stale}/partial".write("interrupted build state")
  let first = execute.build_plan(value, repo_root, object_store, "", 2)?
  assert [node.name for node in value.nodes] == ["execute-dep", "execute-tool", "execute-app"]
  assert [receipt.package_name for receipt in first.artifacts] == ["execute-dep", "execute-tool", "execute-app"]
  assert [receipt.origin for receipt in first.artifacts] == [types.Built, types.Built, types.Built]
  assert store.artifact_path(object_store, node_named(value, "execute-app")?.artifact_key).exists()?
  assert stale.exists()? == false
  assert fp"{repo_root}/packages/execute-app/run-package-build.xsh".exists()? == false

  let second = execute.build_plan(value, repo_root, object_store, "", 3)?
  assert second == first
}

test test_execute_counts_build_hooks_and_reused_artifacts [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-count-repo")?
  let object_store = execute_store(ctx, "execute-count-store")?
  let names = ["execute-dep", "execute-tool", "execute-app"]
  for name in names {
    let recipe = fp"{repo_root}/packages/{name}/PKGBUILD.xsh"
    let source = recipe.read_text()?
    recipe.write(source.replace("  let target =", with: f"  print \"build-hook:{name}\"\n  let target ="))?
  }

  let initial = resolve_execute_plan(repo_root)?
  let first_logs = test.temp_dir(ctx, name: "execute-count-first")?
  let first = execute.build_plan(initial, repo_root, object_store, "", 2, first_logs)?
  assert first.artifacts.len() == 3
  for name in names {
    let log = fp"{first_logs}/{name}.log".read_text()?
    assert log.split(f"build-hook:{name}").len() == 2
  }

  let reuse_logs = test.temp_dir(ctx, name: "execute-count-reuse")?
  let reused = execute.build_plan(initial, repo_root, object_store, "", 2, reuse_logs)?
  assert reused == first
  for name in names {
    assert ! fp"{reuse_logs}/{name}.log".exists()?
  }

  let recipe = fp"{repo_root}/packages/execute-dep/PKGBUILD.xsh"
  recipe.write(recipe.read_text()?.replace("dependency\\n", with: "dependency revision two\\n"))?
  let changed = resolve_execute_plan(repo_root)?
  let changed_logs = test.temp_dir(ctx, name: "execute-count-changed")?
  let rebuilt = execute.build_plan(changed, repo_root, object_store, "", 2, changed_logs)?
  assert rebuilt.artifacts.len() == 3
  for name in ["execute-dep", "execute-app"] {
    let log = fp"{changed_logs}/{name}.log".read_text()?
    assert log.split(f"build-hook:{name}").len() == 2
  }
  assert ! fp"{changed_logs}/execute-tool.log".exists()?
  assert receipt_named(rebuilt, "execute-tool")? == receipt_named(first, "execute-tool")?
}

test test_execute_x86_64_plan_preserves_target_and_metadata [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-x86-repo")?
  let pkgbuild = fp"{repo_root}/packages/execute-dep/PKGBUILD.xsh"
  pkgbuild.write(
    pkgbuild.read_text()?.replace(
      "export let filetree = [{path: p\"usr/share/execute-dep.txt\", kind: \"file\"}]",
      with: "export let filetree = []\n## Target-specific declared output.\nexport let filetree_x86_64 = [{path: p\"usr/share/execute-dep.txt\", kind: \"file\"}]",
    ),
  )
  let proof = fp"{repo_root}/packages/execute-app/proof.xsh"
  proof.write(
    proof.read_text()?.replace(
      "proc main(root: Path = /rootfs) [fs, error] {",
      with: "proc main(root: Path = /rootfs) [fs, env, error] {\n  if env(\"XSH_PM_TARGET_ARCH\")? != \"x86_64\" {\n    return Err(ProofError.Failed(\"proof ran under the wrong target\"))\n  }",
    ),
  )
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
  proof_path.write(proof_path.read_text()? + "\n# proof revision only\n")
  let reproved_plan = resolve_execute_plan(repo_root)?
  let reproved_app = node_named(reproved_plan, "execute-app")?
  assert reproved_app.artifact_key == initial_app.artifact_key
  assert reproved_app.proof_key == initial_app.proof_key == false
  let reproved = execute.build_plan(reproved_plan, repo_root, object_store, "", 2)?
  assert receipt_named(reproved, "execute-app")? == initial_receipt
  assert store.reproof_receipt_path(object_store, reproved_app.artifact_key, reproved_app.proof_key).exists()?
}

test test_execute_parallel_level_requires_published_dependency_receipts [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-level-barrier-repo")?
  write_execute_leaf(repo_root)
  let object_store = execute_store(ctx, "execute-level-barrier-store")?
  let app_proof = fp"{repo_root}/packages/execute-app/proof.xsh"
  app_proof.write(
    """error ProofError = Failed(message: Str)

proc main(root: Path) [error] {
  return Err(ProofError.Failed("intentional level-one proof failure"))
}

main(@args)?
""",
  )
  let value = resolve_execute_plan_for_roots(repo_root, ["execute-leaf"])?
  let app = node_named(value, "execute-app")?
  let leaf = node_named(value, "execute-leaf")?
  assert app.level == 1
  assert leaf.level == 2
  assert [dependency.name for dependency in leaf.dependencies] == ["execute-app"]

  match execute.build_plan(value, repo_root, object_store, "", 2) {
    Ok(_) => test.fail("parallel executor advanced past a failed dependency level")
    Err(problem) => assert "package proof for execute-app" in problem.message
  }

  assert store.artifact_path(object_store, app.artifact_key).exists()? == false
  assert store.artifact_path(object_store, leaf.artifact_key).exists()? == false
}

test test_execute_rebuilds_changed_recipe_and_dependents [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-package-change-repo")?
  let object_store = execute_store(ctx, "execute-package-change-store")?
  let initial = resolve_execute_plan(repo_root)?
  let _ = execute.build_plan(initial, repo_root, object_store, "", 1)?
  let initial_dep = node_named(initial, "execute-dep")?
  let initial_app = node_named(initial, "execute-app")?
  let pkgbuild = fp"{repo_root}/packages/execute-dep/PKGBUILD.xsh"
  pkgbuild.write(pkgbuild.read_text()?.replace("dependency\\n", with: "dependency revision two\\n"))
  let changed = resolve_execute_plan(repo_root)?
  let changed_dep = node_named(changed, "execute-dep")?
  let changed_app = node_named(changed, "execute-app")?
  assert changed_dep.artifact_key == initial_dep.artifact_key == false
  assert changed_app.artifact_key == initial_app.artifact_key == false
  let result = execute.build_plan(changed, repo_root, object_store, "", 1)?
  assert receipt_named(result, "execute-dep")?.key == changed_dep.artifact_key
  assert store.artifact_path(object_store, changed_app.artifact_key).exists()?
  assert receipt_named(result, "execute-app")?.key == changed_app.artifact_key
}

test test_execute_rebuilds_when_package_source_input_changes [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-source-change-repo")?
  let object_store = execute_store(ctx, "execute-source-change-store")?
  let initial = resolve_execute_plan(repo_root)?
  let _ = execute.build_plan(initial, repo_root, object_store, "", 1)?
  let initial_app = node_named(initial, "execute-app")?
  fp"{repo_root}/packages/execute-app/files/input.txt".write("source revision two\n")
  let changed = resolve_execute_plan(repo_root)?
  let changed_app = node_named(changed, "execute-app")?
  assert changed_app.artifact_key == initial_app.artifact_key == false
  let result = execute.build_plan(changed, repo_root, object_store, "", 1)?
  assert receipt_named(result, "execute-app")?.key == changed_app.artifact_key
}

test test_execute_metapackage_keeps_opaque_marker_and_proves_runtime_dependencies [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-meta-repo")?
  write_execute_metapackage(repo_root)
  let value = resolve_execute_plan_for_roots(repo_root, ["execute-meta"])?
  assert [node.name for node in value.nodes] == ["execute-dep", "execute-meta"]
  let object_store = execute_store(ctx, "execute-meta-store")?
  let result = execute.build_plan(value, repo_root, object_store, "", 1)?
  let dependency = receipt_named(result, "execute-dep")?
  let meta = receipt_named(result, "execute-meta")?
  let meta_metadata = json.read(fp"{meta.artifact_dir}/metadata.json")?.require(local.PackageMetadataDto)?
  let files = meta_metadata.files

  assert fp"{meta.artifact_dir}/payload.tar.gz".read_text()? == "laputa metapackage payload marker\n"
  assert meta_metadata.package_kind == "meta"
  assert files == []
  assert fp"{meta.artifact_dir}/proof.json".exists()?
  assert fp"{dependency.artifact_dir}/proof.json".exists()?
}

test test_execute_imports_exact_remote_artifacts_with_other_executor_provenance [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-remote-repo")?
  let local_plan = resolve_execute_plan(repo_root)?
  let local_store = execute_store(ctx, "execute-remote-local-store")?
  let local_result = execute.build_plan(local_plan, repo_root, local_store, "", 1)?
  let remote_root = test.temp_dir(ctx, name: "execute-remote-objects")?
  let initial_snapshot = exact_remote_snapshot(local_plan, local_result, remote_root)?
  let executor = executor_fixture_provenance("same-contract-b")?
  let executor_sha256 = fingerprint.executor_provenance_sha256(executor)?
  let snapshot = remote_snapshot_with_executor(initial_snapshot, remote_root, executor)?
  assert local_result.artifacts[0].executor_sha256 != executor_sha256
  let catalog_value = catalog.load(repo_root)?
  let remote_plan = plan.resolve(catalog_value, snapshot, policy.aarch64_docker(), ["execute-app"], false)?
  assert [types.plan_action_text(node.action) for node in remote_plan.nodes] == [
    "reuse-remote",
    "reuse-remote",
    "reuse-remote",
  ]
  assert [node.artifact_key for node in remote_plan.nodes] == [node.artifact_key for node in local_plan.nodes]

  let imported_store = execute_store(ctx, "execute-remote-imported-store")?
  let imported = execute.build_plan(remote_plan, repo_root, imported_store, f"file://{remote_root}", 1)?
  assert [receipt.origin for receipt in imported.artifacts] == [types.Remote, types.Remote, types.Remote]
  assert [receipt.key for receipt in imported.artifacts] == [node.artifact_key for node in remote_plan.nodes]

  for initial in local_result.artifacts {
    let imported_receipt = receipt_named(imported, initial.package_name)?
    assert imported_receipt.executor_sha256 == executor_sha256
    assert imported_receipt.payload_sha256 == initial.payload_sha256
  }
}

test test_execute_cached_reproof_failure_reports_context_and_corrupt_final_never_publishes_replacement [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-proof-failure-repo")?
  let object_store = execute_store(ctx, "execute-proof-failure-store")?
  let initial_plan = resolve_execute_plan(repo_root)?
  let initial_result = execute.build_plan(initial_plan, repo_root, object_store, "", 1)?
  let initial_app = node_named(initial_plan, "execute-app")?
  let initial_receipt = receipt_named(initial_result, "execute-app")?
  let proof_path = fp"{repo_root}/packages/execute-app/proof.xsh"
  proof_path.write(
    """error ProofError = Failed(message: Str)

proc main(root: Path = /rootfs) [error] {
  return Err(ProofError.Failed(\"intentional proof failure\"))
}

main(@args)?
""",
  )
  let failed_plan = resolve_execute_plan(repo_root)?
  let failed_app = node_named(failed_plan, "execute-app")?
  assert failed_app.artifact_key == initial_app.artifact_key
  assert failed_app.proof_key != initial_app.proof_key
  let saved_plan = test.temp_path(ctx, name: "execute-proof-failure-plan.json")
  plan_json.write_plan(saved_plan, failed_plan)
  let failure_output = execute_plan_output(ctx, saved_plan, repo_root, object_store)?

  assert ! failure_output.success, failure_output.stderr
  assert f"(ctx: proving package {failed_app.package_id})" in failure_output.stderr, failure_output.stderr
  assert "package proof for execute-app exited with status 3" in failure_output.stderr, failure_output.stderr
  assert store.lookup(object_store, failed_app.artifact_key)? == initial_receipt
  assert ! store.reproof_receipt_path(object_store, failed_app.artifact_key, failed_app.proof_key).exists()?

  assert store.artifact_path(object_store, failed_app.artifact_key).exists()?

  let healthy_repo = copied_execute_repository(ctx, "execute-corrupt-repo")?
  let healthy_plan = resolve_execute_plan(healthy_repo)?
  let healthy_store = execute_store(ctx, "execute-corrupt-store")?
  let healthy = execute.build_plan(healthy_plan, healthy_repo, healthy_store, "", 1)?
  let healthy_app = node_named(healthy_plan, "execute-app")?
  let final_dir = store.artifact_path(healthy_store, healthy_app.artifact_key)
  fp"{final_dir}/payload.tar.gz".write("corrupt final payload")

  let reused = execute.build_plan(healthy_plan, healthy_repo, healthy_store, "", 1)?
  assert reused == healthy
  assert fp"{final_dir}/payload.tar.gz".read_text()? == "corrupt final payload"

  match store.verify_artifact(healthy_store, healthy_app.artifact_key) {
    Ok(_) => test.fail("corrupt final artifact unexpectedly verified")
    Err(problem) => assert "payload SHA-256 does not match receipt" in problem.message
  }
}

test test_execute_build_failure_reports_package_context_and_original_status [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-build-failure-repo")?
  let recipe_path = fp"{repo_root}/packages/execute-app/PKGBUILD.xsh"
  let source = recipe_path.read_text()?
  let broken = source.replace(
    "  let root = env(\"LAPUTA_ROOT\")?",
    with: "  error.fail(\"intentional build failure\")?\n  let root = env(\"LAPUTA_ROOT\")?",
  )
  assert broken != source
  recipe_path.write(broken)
  let value = resolve_execute_plan(repo_root)?
  let app = node_named(value, "execute-app")?
  let object_store = execute_store(ctx, "execute-build-failure-store")?
  let saved_plan = test.temp_path(ctx, name: "execute-build-failure-plan.json")
  plan_json.write_plan(saved_plan, value)
  let failure_output = execute_plan_output(ctx, saved_plan, repo_root, object_store)?

  assert ! failure_output.success, failure_output.stderr
  assert f"(ctx: building package {app.package_id})" in failure_output.stderr, failure_output.stderr
  assert "package build for execute-app exited with status 3" in failure_output.stderr, failure_output.stderr
  assert ! store.artifact_path(object_store, app.artifact_key).exists()?
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
  let saved_path = fp"{object_store}/saved-plan.json"
  plan_json.write_plan(saved_path, value)
  let saved = plan_json.read(saved_path)?
  assert saved == value

  match execute.build_plan(saved, repo_root, object_store, "", 1) {
    Ok(_) => test.fail("plan from another BUILD_EPOCH unexpectedly executed")
    Err(problem) => assert f"resolved at BUILD_EPOCH {policy.BUILD_EPOCH + 1}" in problem.message
  }

  assert fp"{object_store}/v2".exists()? == false
}

type TraceSpanDto = {file: Str}

type TraceEventDto = {kind: Str, name: Str?, source_span: TraceSpanDto?}

proc sha256_calls_by_module(trace: Path) -> Result[Map[Int]] {
  var counts: Map[Int] = {}

  for line in trace.read_text()?.split("\n") {
    continue when line.trim() == ""
    let event = json.decode(line)?.require(TraceEventDto)?
    continue unless event.kind == "module.call" and event.name == "hash.sha256"
    let span = event.source_span
    let module_name = if span == null { "unknown" } else { fp"{span.file}".name }
    counts[module_name] = (counts.get(module_name) ?? 0) + 1
  }

  counts
}

test test_execute_hashes_each_payload_once_and_reuse_hashes_nothing [fs, process, env, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-hash-count-repo")?
  let object_store = execute_store(ctx, "execute-hash-count-store")?
  let plan_path = test.temp_path(ctx, name: "execute-hash-count-plan.json")
  plan_json.write_plan(plan_path, resolve_execute_plan(repo_root)?)
  let source = r"""use pm.execute
use pm.plan_json

proc main(plan_path: Path, repo_root: Path, object_store: Path) [fs, net, process, env, time, error] {
  let _ = execute.build_plan(plan_json.read(plan_path)?, repo_root, object_store, "", 1)?
}

main(@args)?
"""
  let modules = path.absolute(p".")?
  let runs: List[Map[Int]] = collect {
    for name in ["fresh", "reuse"] {
      let trace = test.temp_path(ctx, name: f"execute-hash-count-{name}.jsonl")
      let outcome = test.run_xsht_trace(
        ctx,
        source,
        ["--raw", "--trace-format", "jsonl", "--trace-file", trace.display()],
        [plan_path.display(), repo_root.display(), object_store.display()],
        {XSH_MODULE_PATH: modules},
      )?
      assert outcome.success
      yield sha256_calls_by_module(trace)?
    }
  }

  let fresh = runs[0]
  assert (fresh.get("execute.xsh") ?? 0) == 3
  assert (fresh.get("store.xsh") ?? 0) == 6
  assert (fresh.get("proof.xsh") ?? 0) == 0
  assert (fresh.get("root.xsh") ?? 0) == 0

  let reuse = runs[1]
  test.eq(reuse.keys() |> sort, [])
}

test test_execute_keeps_runtime_only_dependency_out_of_build_root_and_composes_it [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-runtime-only-repo")?
  write_execute_service(repo_root)
  let value = resolve_execute_plan_for_roots(repo_root, ["execute-service"])?
  assert [node.name for node in value.nodes] == ["execute-dep", "execute-service"]
  assert [node.level for node in value.nodes] == [0, 0]

  let object_store = execute_store(ctx, "execute-runtime-only-store")?
  let result = execute.build_plan(value, repo_root, object_store, "", 1)?
  let service = receipt_named(result, "execute-service")?
  assert service.dependency_keys == []
  assert service.runtime_dependency_keys == []

  let overlay = fp"{test.temp_dir(ctx, name: "execute-runtime-only-overlay")?}/overlay"
  overlay.mkdir()
  let generation_plan = generation.plan(value, ["execute-service"], generation.overlay_digest(overlay)?)?
  assert [artifact.package_name for artifact in generation_plan.artifacts] == ["execute-dep", "execute-service"]
  let output = fp"{test.temp_dir(ctx, name: "execute-runtime-only-generation")?}/root"
  let receipt = generation.compose(generation_plan, object_store, output, overlay)?
  assert fp"{output}/usr/share/execute-dep.txt".read_text()? == "dependency\n"
  assert fp"{output}/usr/share/execute-service.txt".read_text()? == "service\n"
  generation.verify_generation(output, receipt)
}

test test_execute_parallel_builds_log_per_package_and_failures_name_their_log [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-logs-repo")?
  let value = resolve_execute_plan(repo_root)?
  let logs = test.temp_dir(ctx, name: "execute-logs")?
  let _ = execute.build_plan(value, repo_root, execute_store(ctx, "execute-logs-store")?, "", 2, logs)?

  for name in ["execute-dep", "execute-tool", "execute-app"] {
    assert fp"{logs}/{name}.log".exists()?, f"{name} has a log"
  }

  fp"{repo_root}/packages/execute-app/proof.xsh".write(
    """error ProofError = Failed(message: Str)

proc main(root: Path) [error] {
  return Err(ProofError.Failed("intentional proof failure"))
}

main(@args)?
""",
  )
  let failing = resolve_execute_plan(repo_root)?
  let failed_logs = test.temp_dir(ctx, name: "execute-failed-logs")?

  match execute.build_plan(failing, repo_root, execute_store(ctx, "execute-failed-store")?, "", 2, failed_logs) {
    Ok(_) => test.fail("a failing proof built")
    Err(problem) => {
      assert f"{failed_logs}/execute-app.log" in problem.message, problem.message
      assert "intentional proof failure" in problem.message, problem.message
    }
  }
}

test test_execute_composes_proof_tools_without_build_or_generation_leakage_and_reproofs_tool_changes [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-proof-dependencies")?
  write_execute_service(repo_root)
  let package = fp"{repo_root}/packages/execute-service"
  let recipe_path = fp"{package}/PKGBUILD.xsh"
  recipe_path.write(recipe_path.read_text()?.replace("export let runtime_only_deps = [\"execute-dep\"]", with: "export let runtime_only_deps = []"))
  fp"{package}/proof_deps.xsh".write("##! Proof dependency fixture.\n## Declared proof tool.\nexport let proof_deps = [\"execute-dep\"]\n")
  let proof_path = fp"{package}/proof.xsh"
  proof_path.write(proof_path.read_text()?.replace("proc main(root: Path = /rootfs) [fs, error] {", with: "proc main(root: Path = /rootfs) [fs, error] {\n  if ! fp\"{root}/usr/share/execute-dep.txt\".exists()? { return Err(ProofError.Failed(\"missing declared proof tool\")) }"))
  let value = resolve_execute_plan_for_roots(repo_root, ["execute-service"])?
  let service_node = node_named(value, "execute-service")?
  assert node_named(value, "execute-dep")?.level < service_node.level
  let object_store = execute_store(ctx, "execute-proof-dependencies-store")?
  let result = execute.build_plan(value, repo_root, object_store, "", 2)?
  let service = receipt_named(result, "execute-service")?
  assert service.dependency_keys == []
  assert service.runtime_dependency_keys == []
  let overlay = fp"{test.temp_dir(ctx, name: "execute-proof-overlay")?}/overlay"
  overlay.mkdir()
  let generation_plan = generation.plan(value, ["execute-service"], generation.overlay_digest(overlay)?)?
  assert [artifact.package_name for artifact in generation_plan.artifacts] == ["execute-service"]
  let dependency_recipe = fp"{repo_root}/packages/execute-dep/PKGBUILD.xsh"
  dependency_recipe.write(dependency_recipe.read_text()?.replace("ver = \"1.0.0\"", with: "ver = \"1.0.1\""))
  let changed = resolve_execute_plan_for_roots(repo_root, ["execute-service"])?
  let changed_service = node_named(changed, "execute-service")?
  assert changed_service.artifact_key == service_node.artifact_key
  assert changed_service.proof_key != service_node.proof_key
  let reproved = execute.build_plan(changed, repo_root, object_store, "", 2)?
  assert receipt_named(reproved, "execute-service")? == service
  assert store.reproof_receipt_path(object_store, changed_service.artifact_key, changed_service.proof_key).exists()?
}

test test_execute_rejects_changed_evaluated_proof_dependencies_before_building_a_saved_plan [fs, process, env, error] { |ctx|
  let repo_root = copied_execute_repository(ctx, "execute-evaluated-proof-dependencies")?
  write_execute_service(repo_root)
  let package = fp"{repo_root}/packages/execute-service"
  let recipe_path = fp"{package}/PKGBUILD.xsh"
  recipe_path.write(recipe_path.read_text()?.replace("export let runtime_only_deps = [\"execute-dep\"]", with: "export let runtime_only_deps = []"))
  let declarations = fp"{package}/proof_deps.xsh"
  let declaration = "##! Evaluated proof dependencies.\n## Environment-selected proof tool.\nexport let proof_deps = [e\"LAPUTA_TEST_PROOF_TOOL\" ?? \"execute-dep\"]\n"
  declarations.write(declaration)
  let initial_path = test.temp_path(ctx, name: "evaluated-proof-initial.json")
  let changed_path = test.temp_path(ctx, name: "evaluated-proof-changed.json")
  let object_store = execute_store(ctx, "execute-evaluated-proof-store")?
  let modules = path.absolute(p".")?
  let source = r"""use pm.catalog
use pm.execute
use pm.plan
use pm.plan_json
use pm.policy
use pm.types
proc main(mode: Str, repo: Path, plan_path: Path, object_store: Path) [fs, net, process, env, time, error] {
  if mode == "plan" {
    let remote: types.RemoteSnapshot = {target: types.target_aarch64(), index_sha256: "evaluated-proof-remote", packages: []}
    let resolved = plan.resolve(catalog.load(repo)?, remote, policy.aarch64_docker(), ["execute-service"], false)?
    plan_json.write_plan(plan_path, resolved)
  } else {
    let _ = execute.build_plan(plan_json.read(plan_path)?, repo, object_store, "", 1)?
  }
}
main(@args)?
"""
  for selection in [{tool: "execute-dep", plan_path: initial_path}, {tool: "execute-tool", plan_path: changed_path}] {
    let planned = test.run_xsh(ctx, source, [], ["plan", repo_root.display(), selection.plan_path.display(), object_store.display()], {XSH_MODULE_PATH: modules, LAPUTA_TEST_PROOF_TOOL: selection.tool})?
    assert planned.success, planned.stderr
  }
  let stale = test.run_xsh(ctx, source, [], ["execute", repo_root.display(), initial_path.display(), object_store.display()], {XSH_MODULE_PATH: modules, LAPUTA_TEST_PROOF_TOOL: "execute-tool"})?
  assert ! stale.success, "an unbuilt saved plan accepted a different evaluated proof dependency list"
  assert "recipe proof input changed after plan creation for execute-service" in stale.stderr
  let initial = plan_json.read(initial_path)?
  let changed = plan_json.read(changed_path)?
  let before = node_named(initial, "execute-service")?
  let after = node_named(changed, "execute-service")?
  assert before.recipe_sha256 == after.recipe_sha256
  assert before.artifact_key == after.artifact_key
  assert before.proof_sha256 != after.proof_sha256
  assert before.proof_key != after.proof_key
  assert declarations.read_text()? == declaration
}
