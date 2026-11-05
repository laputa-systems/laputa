##! Behavior coverage for verified BuildPlan repository snapshots and immutable file publication.
use pm.catalog
use pm.execute as execute
use pm.local as local
use pm.plan
use pm.plan_json
use pm.policy
use pm.proof as pm_proof
use pm.remote
use pm.repo
use pm.store
use pm.types
use pm.util as pm_util

type AdditionalMetadataDto = {source: Str}

type PublishedArchDto = {arch: Str, target: Str}

type PublishedMetadataDto = {
  additional_metadata: AdditionalMetadataDto,
  target: Str,
  artifact_key: Str,
  recipe_sha256: Str,
  executor_sha256: Str,
  proof_key: Str,
  proof_sha256: Str,
}

pure fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/{name}"
}

pure publish_executor_sha256() -> Str {
  bytes.from_text("publish executor").sha256().hex()
}

pure publish_empty_remote() -> types.RemoteSnapshot {
  {target: types.Aarch64LinuxMusl, index_sha256: "publish-empty-remote", packages: []}
}

proc copied_publish_repository(ctx: TestContext, name: Str) [fs, env, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name:)?
  let _ = fs.copy_tree(fixture("graph-catalog/packages"), fp"{root}/packages", parents: true, overwrite: true)?
  fp"{root}/pm".mkdir()
  p"pm/proof.xsh".copy(to: fp"{root}/pm/proof.xsh", overwrite: true)
  root
}

proc publish_plan(ctx: TestContext, name: Str) -> Result[types.BuildPlan] {
  let repo_root = copied_publish_repository(ctx, name)?
  plan_publish_repository(repo_root)?
}

proc plan_publish_repository(repo_root: Path) -> Result[types.BuildPlan] {
  let catalog_value = catalog.load_for_target(repo_root, types.target_aarch64())?
  plan.resolve(catalog_value, publish_empty_remote(), policy.aarch64_docker(), ["app"], false)?
}

proc publish_repository_once(ctx: TestContext, repo_root: Path, remote_url: Str, name: Str) -> Result[types.BuildPlan] {
  let value = plan_publish_repository(repo_root)?
  let store_root = test.temp_dir(ctx, name: f"{name}-store")?
  stage_plan_artifacts(ctx, value, store_root)
  repo.publish(repo.snapshot(value, store_root)?, remote_url, "", test.temp_dir(ctx, name: f"{name}-work")?)
  value
}

proc index_row(index: List[types.RemotePackage], name: Str) [error] -> Result[types.RemotePackage] {
  for entry in index {
    return entry when entry.name == name
  }

  Err(types.PmError.PackageContract(f"missing index row {name}"))
}

proc node_named(value: types.BuildPlan, name: Str) [error] -> Result[types.PlanNode] {
  for node in value.nodes {
    return node when node.name == name
  }

  Err(types.PmError.PackageContract(f"missing published node {name}"))
}

pure remote_decoder_row(metapackage: Bool, tarball: Str, sha256: Str, size: Int) -> Record {
  {
    arch: "aarch64",
    name: "decoder",
    ver: "1",
    rel: "1",
    deps: [],
    runtime_only_deps: [],
    mkdeps_host: [],
    mkdeps_target: [],
    sha256,
    size,
    tarball,
    metadata: "metadata/aarch64/decoder/decoder-1-1.json",
    metadata_sha256: "",
    artifact_key: "",
    recipe_sha256: "",
    executor_sha256: "",
    proof_key: "",
    proof_sha256: "",
    proof: "",
    proof_receipt_sha256: "",
    source_sha256: "",
    metapackage,
  }
}

proc stage_plan_artifacts(
  ctx: TestContext,
  value: types.BuildPlan,
  store_root: Path,
  valid_proofs = true,
  include_package_kind = true,
  package_kind = "payload",
  target: types.Target = types.target_aarch64(),
  dependency_order: List[Str] = [],
) {
  let executor_sha256 = publish_executor_sha256()
  let arch = types.pm_target_arch(target)

  for node in value.nodes {
    let staged_root = test.temp_dir(ctx, name: f"publish-stage-{node.name}")?
    let payload = fp"{staged_root}/payload.tar.gz"
    let metadata = fp"{staged_root}/metadata.json"
    let proof = fp"{staged_root}/proof.json"
    payload.write(if package_kind == "meta" { "laputa metapackage payload marker\n" } else { f"payload {node.package_id}\n" })
    let payload_sha256 = hash.sha256(payload)?.hex()
    let runtime_dependencies = [
      dependency.name for dependency in node.dependencies if dependency.kind == types.dependency_runtime()
    ]
    if include_package_kind {
      json.write(
        metadata,
        {
          arch,
          name: node.name,
          additional_metadata: {source: "recipe"},
          ver: node.ver,
          rel: node.rel,
          deps: if dependency_order.is_empty() or runtime_dependencies.is_empty() { runtime_dependencies } else { dependency_order },
          runtime_only_deps: [
            dependency.name for dependency in node.dependencies if dependency.kind == types.dependency_runtime_only()
          ],
          mkdeps_host: [dependency.name for dependency in node.dependencies if dependency.kind == types.dependency_build_host()],
          mkdeps_target: [dependency.name for dependency in node.dependencies if dependency.kind == types.dependency_build_target()],
          package_kind,
          filetree: [],
          manifest: [],
          metadata_sha256: "",
          files: [],
        },
      )
    } else {
      json.write(
        metadata,
        {
          arch,
          name: node.name,
          additional_metadata: {source: "recipe"},
          ver: node.ver,
          rel: node.rel,
          deps: [dependency.name for dependency in node.dependencies if dependency.kind == types.dependency_runtime()],
          runtime_only_deps: [
            dependency.name for dependency in node.dependencies if dependency.kind == types.dependency_runtime_only()
          ],
          mkdeps_host: [dependency.name for dependency in node.dependencies if dependency.kind == types.dependency_build_host()],
          mkdeps_target: [dependency.name for dependency in node.dependencies if dependency.kind == types.dependency_build_target()],
          filetree: [],
          manifest: [],
          metadata_sha256: "",
          files: [],
        },
      )
    }

    if valid_proofs {
      pm_proof.write_artifact_receipt(proof, node, payload_sha256)
    } else {
      proof.write("not a package proof receipt\n")
    }

    let _ = store.commit(target, store_root, node, {payload, payload_sha256, metadata, proof, executor_sha256})?
  }
}

proc expect_snapshot_error(_: TestContext, value: types.BuildPlan, store_root: Path, expected: Str) {
  match repo.snapshot(value, store_root) {
    Ok(_) => test.fail(f"{expected}: snapshot unexpectedly succeeded")
    Err(problem) => assert expected in problem.message
  }
}

test test_snapshot_defaults_only_omitted_legacy_package_kind_to_payload [fs, env, error] { |ctx|
  let value = publish_plan(ctx, "publish-legacy-package-kind-repo")?
  let legacy_store = test.temp_dir(ctx, name: "publish-legacy-package-kind-store")?
  stage_plan_artifacts(ctx, value, legacy_store, true, false)
  let legacy = repo.snapshot(value, legacy_store)?

  for publication in legacy.packages {
    assert publication.kind == types.package_payload()
  }

  let invalid_store = test.temp_dir(ctx, name: "publish-invalid-package-kind-store")?
  stage_plan_artifacts(ctx, value, invalid_store, true, true, "")
  expect_snapshot_error(ctx, value, invalid_store, "invalid package kind")
}

test test_snapshot_rejects_missing_unproved_and_corrupt_plan_artifacts [fs, env, error] { |ctx|
  let value = publish_plan(ctx, "publish-missing-repo")?
  let missing_store = test.temp_dir(ctx, name: "publish-missing-store")?
  expect_snapshot_error(ctx, value, missing_store, "is missing")

  let unproved_store = test.temp_dir(ctx, name: "publish-unproved-store")?
  stage_plan_artifacts(ctx, value, unproved_store, valid_proofs: false)
  match repo.snapshot(value, unproved_store) {
    Ok(_) => test.fail("snapshot accepted a malformed proof receipt")
    Err(problem) => assert problem is InvalidData
  }

  let incomplete_store = test.temp_dir(ctx, name: "publish-incomplete-store")?
  stage_plan_artifacts(ctx, value, incomplete_store)
  let incomplete_app = node_named(value, "app")?
  fp"{store.artifact_path(incomplete_store, incomplete_app.artifact_key)}/metadata.json".remove(missing_ok: false)
  expect_snapshot_error(ctx, value, incomplete_store, "incomplete")

  let corrupt_store = test.temp_dir(ctx, name: "publish-corrupt-store")?
  stage_plan_artifacts(ctx, value, corrupt_store)
  let app = node_named(value, "app")?
  fp"{store.artifact_path(corrupt_store, app.artifact_key)}/payload.tar.gz".write("corrupt payload")
  expect_snapshot_error(ctx, value, corrupt_store, "payload SHA-256 does not match receipt")
}

test test_publish_file_snapshot_is_exact_deterministic_and_idempotent [fs, net, env, time, error] { |ctx|
  let value = publish_plan(ctx, "publish-file-repo")?
  let store_root = test.temp_dir(ctx, name: "publish-file-store")?
  stage_plan_artifacts(ctx, value, store_root)
  let snapshot = repo.snapshot(value, store_root)?
  let remote_root = test.temp_dir(ctx, name: "publish-file-remote")?
  let work = test.temp_dir(ctx, name: "publish-file-work")?
  let remote_url = f"file://{remote_root}"
  repo.publish(snapshot, remote_url, "", work)

  let index = remote.load_remote_index_from(fp"{remote_root}/index.json")?
  assert [entry.name for entry in index] == ["app", "host-tool", "runtime-lib", "target-sdk"]
  let app = node_named(value, "app")?
  let entry = index[0]
  assert entry.artifact_key == app.artifact_key
  assert entry.proof_key == app.proof_key
  assert entry.proof_sha256 == app.proof_sha256
  assert entry.metadata_sha256 != ""
  assert entry.tarball == pm_util.remote_binary_rel("aarch64", app.name, app.ver, app.rel, app.artifact_key).display()
  assert entry.tarball == f"packages/aarch64/app/app-1-1-{app.artifact_key.byte_slice(0, 12)}.tar.gz"
  assert entry.metadata == f"metadata/aarch64/app/app-1-1-{app.artifact_key.byte_slice(0, 12)}-{app.proof_key.byte_slice(0, 12)}.json"
  assert entry.proof == f"proofs/aarch64/app/app-1-1-{app.artifact_key.byte_slice(0, 12)}-{app.proof_key.byte_slice(0, 12)}.json"
  assert fp"{remote_root}/{entry.tarball}".exists()?
  assert fp"{remote_root}/{entry.metadata}".exists()?
  assert fp"{remote_root}/{entry.proof}".exists()?
  let metadata = json.read(fp"{remote_root}/{entry.metadata}")?.require(PublishedMetadataDto)?
  assert metadata.additional_metadata.source == "recipe"
  assert metadata.target == "aarch64-linux-musl"
  assert metadata.artifact_key == app.artifact_key
  assert metadata.recipe_sha256 == app.recipe_sha256
  assert metadata.executor_sha256 == publish_executor_sha256()
  assert metadata.proof_key == app.proof_key
  assert metadata.proof_sha256 == app.proof_sha256

  let first_index = fp"{remote_root}/index.json".read_text()?
  repo.publish(snapshot, remote_url, "", work)
  assert fp"{remote_root}/index.json".read_text()? == first_index
}

test test_publish_index_lists_runtime_only_dependencies_beside_deps [fs, net, env, time, error] { |ctx|
  let repo_root = copied_publish_repository(ctx, "publish-runtime-only-repo")?
  let service = fp"{repo_root}/packages/service"
  service.mkdir()
  fp"{service}/PKGBUILD.xsh".write(
    """##! Publication fixture with a runtime-only dependency.
## Package name.
export let name = "service"
## Metadata-only package kind.
export let package_kind = "meta"
## Package version.
export let ver = "1"
## Package release.
export let rel = "1"
## Build-root dependencies.
export let deps = ["runtime-lib"]
## Installed only by root composition.
export let runtime_only_deps = ["app"]
## No build-host dependencies.
export let mkdeps_host = []
## No upstream source inputs.
export let upstream_sources = []
## No payload files.
export let filetree = []
""",
  )
  let value = plan.resolve(
    catalog.load(repo_root)?,
    publish_empty_remote(),
    policy.aarch64_docker(),
    ["service"],
    false,
  )?
  let store_root = test.temp_dir(ctx, name: "publish-runtime-only-store")?
  stage_plan_artifacts(ctx, value, store_root)
  let remote_root = test.temp_dir(ctx, name: "publish-runtime-only-remote")?
  repo.publish(
    repo.snapshot(value, store_root)?,
    f"file://{remote_root}",
    "",
    test.temp_dir(ctx, name: "publish-runtime-only-work")?,
  )

  let index = remote.load_remote_index_from(fp"{remote_root}/index.json")?
  assert [entry.name for entry in index] == ["app", "host-tool", "runtime-lib", "service", "target-sdk"]

  for entry in index {
    if entry.name == "service" {
      assert entry.deps == ["runtime-lib"]
      assert entry.runtime_only_deps == ["app"]
    } else {
      assert entry.runtime_only_deps == []
    }
  }
}

test test_published_metapackage_imports_without_a_payload_object [fs, net, process, env, time, error] { |ctx|
  let repo_root = copied_publish_repository(ctx, "publish-meta-import-repo")?
  let selector = fp"{repo_root}/packages/selector"
  selector.mkdir()
  fp"{selector}/PKGBUILD.xsh".write(
    """##! Published metadata-only selector fixture.
## Package name.
export let name = "selector"
## Explicit package classification.
export let package_kind = "meta"
## Package version.
export let ver = "1"
## Package release.
export let rel = "1"
## Runtime dependencies.
export let deps = ["target-sdk", "runtime-lib"]
## Runtime-only dependencies.
export let runtime_only_deps = []
## Host build dependencies.
export let mkdeps_host = []
## Target build dependencies.
export let mkdeps_target = []
## Fixture sources.
export let upstream_sources = []
## Metapackages have no payload files.
export let filetree = []
""",
  )
  let target = types.target_aarch64()
  let local_plan = plan.resolve(
    catalog.load_for_target(repo_root, target)?,
    publish_empty_remote(),
    policy.aarch64_docker(),
    ["selector"],
    false,
  )?
  let local_store = test.temp_dir(ctx, name: "publish-meta-import-local-store")?
  stage_plan_artifacts(
    ctx,
    local_plan,
    local_store,
    package_kind: "meta",
    dependency_order: ["target-sdk", "runtime-lib"],
  )
  let remote_root = test.temp_dir(ctx, name: "publish-meta-import-remote")?
  let remote_url = f"file://{remote_root}"
  repo.publish(
    repo.snapshot(local_plan, local_store)?,
    remote_url,
    "",
    test.temp_dir(ctx, name: "publish-meta-import-work")?,
  )

  let index_path = fp"{remote_root}/index.json"
  let index = remote.load_remote_index_from(index_path)?
  let selector_row = index_row(index, "selector")?
  assert selector_row.metapackage
  assert selector_row.deps == ["runtime-lib", "target-sdk"]
  assert selector_row.tarball == ""
  assert selector_row.sha256 == ""
  assert selector_row.size == 0
  assert fp"{remote_root}/packages/aarch64/selector/selector-1-1.tar.gz".exists()? == false

  let index_cache = test.temp_dir(ctx, name: "publish-meta-import-index-cache")?
  let remote_packages: List[types.RemotePlanArtifact] = [
    remote.plan_artifact_from_package_at_repo(entry, remote_url, index_cache)?
    for entry in index
  ]
  let remote_snapshot: types.RemoteSnapshot = {
    target,
    index_sha256: hash.sha256(index_path)?.hex(),
    packages: remote_packages,
  }
  let imported_plan = plan.resolve(
    catalog.load_for_target(repo_root, target)?,
    remote_snapshot,
    policy.aarch64_docker(),
    ["selector"],
    false,
  )?
  let selector_node = node_named(imported_plan, "selector")?
  assert types.plan_action_text(selector_node.action) == "reuse-remote"
  assert [dependency.name for dependency in selector_node.dependencies] == ["runtime-lib", "target-sdk"]

  let serialized_plan = fp"{test.temp_dir(ctx, name: "publish-meta-import-plan")?}/plan.json"
  plan_json.write_plan(serialized_plan, imported_plan)
  let round_tripped = plan_json.read(serialized_plan)?
  let imported_store = test.temp_dir(ctx, name: "publish-meta-import-imported-store")?
  let result = execute.build_plan(round_tripped, repo_root, imported_store, remote_url, 1)?
  let selector_receipt = [receipt for receipt in result.artifacts if receipt.package_name == "selector"][0]
  let marker = fp"{selector_receipt.artifact_dir}/payload.tar.gz"
  let marker_hash = bytes.from_text("laputa metapackage payload marker\n").sha256().hex()
  assert marker.read_text()? == "laputa metapackage payload marker\n"
  assert hash.sha256(marker)?.hex() == marker_hash
  let metadata = json.read(fp"{selector_receipt.artifact_dir}/metadata.json")?.require(local.PackageMetadataDto)?
  assert metadata.package_kind == "meta"
  assert metadata.filetree.is_empty()
  assert metadata.manifest.is_empty()
  assert metadata.files.is_empty()
  assert selector_receipt.dependency_keys == [
    node_named(imported_plan, "runtime-lib")?.artifact_key,
    node_named(imported_plan, "target-sdk")?.artifact_key,
  ]

  let selector_artifact = [package for package in remote_packages if package.name == "selector"][0]
  let remote_metadata = fp"{remote_root}/{selector_row.metadata}"
  let original_metadata: local.PackageMetadataDto = json.read(remote_metadata)?.require(local.PackageMetadataDto)?
  let selector_remote_node = {...selector_node, remote: selector_artifact.retrieval}
  json.write(remote_metadata, {...original_metadata, package_kind: "payload"})
  let wrong_kind_node = {
    ...selector_remote_node,
    remote: {
      ...selector_artifact.retrieval,
      metadata_sha256: hash.sha256(remote_metadata)?.hex(),
    },
  }
  let wrong_kind_store = test.temp_dir(ctx, name: "publish-meta-import-wrong-kind-store")?

  match store.import_remote(
    target,
    wrong_kind_store,
    wrong_kind_node,
    remote_url,
    test.temp_dir(ctx, name: "publish-meta-import-wrong-kind-cache")?,
  ) {
    Ok(_) => test.fail("metadata-only retrieval accepted payload metadata")
    Err(problem) => assert "declares a payload" in problem.message
  }

  assert store.artifact_path(wrong_kind_store, selector_node.artifact_key).exists()? == false
  json.write(remote_metadata, {...original_metadata, filetree: [{path: "bin/invalid", kind: "file"}]})
  let inventory_node = {
    ...selector_remote_node,
    remote: {
      ...selector_artifact.retrieval,
      metadata_sha256: hash.sha256(remote_metadata)?.hex(),
    },
  }
  let inventory_store = test.temp_dir(ctx, name: "publish-meta-import-inventory-store")?

  match store.import_remote(
    target,
    inventory_store,
    inventory_node,
    remote_url,
    test.temp_dir(ctx, name: "publish-meta-import-inventory-cache")?,
  ) {
    Ok(_) => test.fail("metadata-only retrieval accepted a nonempty payload inventory")
    Err(problem) => assert "declares payload files" in problem.message
  }

  assert store.artifact_path(inventory_store, selector_node.artifact_key).exists()? == false

  let extra_dependency_metadata = {...original_metadata, deps: ["runtime-lib", "target-sdk", "unexpected"]}
  json.write(remote_metadata, extra_dependency_metadata)
  let extra_dependency_node = {
    ...selector_remote_node,
    remote: {
      ...selector_artifact.retrieval,
      metadata_sha256: hash.sha256(remote_metadata)?.hex(),
    },
  }

  match store.import_remote(
    target,
    test.temp_dir(ctx, name: "publish-meta-import-extra-dependency-store")?,
    extra_dependency_node,
    remote_url,
    test.temp_dir(ctx, name: "publish-meta-import-extra-dependency-cache")?,
  ) {
    Ok(_) => test.fail("metadata-only retrieval accepted an undeclared dependency")
    Err(problem) => assert "dependencies do not match" in problem.message
  }

  let duplicate_dependency_metadata = {...original_metadata, deps: ["runtime-lib", "runtime-lib", "target-sdk"]}
  json.write(remote_metadata, duplicate_dependency_metadata)
  let duplicate_dependency_node = {
    ...selector_remote_node,
    remote: {
      ...selector_artifact.retrieval,
      metadata_sha256: hash.sha256(remote_metadata)?.hex(),
    },
  }

  match store.import_remote(
    target,
    test.temp_dir(ctx, name: "publish-meta-import-duplicate-dependency-store")?,
    duplicate_dependency_node,
    remote_url,
    test.temp_dir(ctx, name: "publish-meta-import-duplicate-dependency-cache")?,
  ) {
    Ok(_) => test.fail("metadata-only retrieval accepted a duplicate dependency")
    Err(problem) => assert "dependencies do not match" in problem.message
  }
}

test test_remote_decoder_keeps_payload_states_unambiguous [fs, net, env, error] { |ctx|
  let empty_meta = remote.decode_remote_package(remote_decoder_row(true, "", "", 0))?
  let meta_plan = remote.plan_artifact_from_package(empty_meta)?
  assert types.remote_payload_is_metadata_only(meta_plan.retrieval.payload)
  assert types.remote_payload_tarball(meta_plan.retrieval.payload) == ""
  assert types.remote_payload_sha256(meta_plan.retrieval.payload) == ""

  let empty_legacy = remote.decode_remote_package(remote_decoder_row(false, "", "", 0))?
  let legacy_plan = remote.plan_artifact_from_package(empty_legacy)?
  assert ! types.remote_payload_is_metadata_only(legacy_plan.retrieval.payload)
  assert types.remote_payload_tarball(legacy_plan.retrieval.payload) == "packages/aarch64/decoder/decoder-1-1.tar.gz"
  assert types.remote_payload_sha256(legacy_plan.retrieval.payload) != ""

  let archive_row = remote.decode_remote_package(remote_decoder_row(false, "packages/aarch64/decoder/decoder-1-1.tar.gz", "payload", 7))?
  let archive_plan = remote.plan_artifact_from_package(archive_row)?
  assert ! types.remote_payload_is_metadata_only(archive_plan.retrieval.payload)
  assert types.remote_payload_tarball(archive_plan.retrieval.payload) == archive_row.tarball
  assert types.remote_payload_sha256(archive_plan.retrieval.payload) == archive_row.sha256

  match remote.decode_remote_package(remote_decoder_row(false, "packages/aarch64/decoder/decoder-1-1.tar.gz", "", 7)) {
    Ok(_) => test.fail("partial archive coordinates unexpectedly decoded")
    Err(problem) => assert "declared together" in problem.message
  }

  match remote.decode_remote_package(remote_decoder_row(true, "packages/aarch64/decoder/decoder-1-1.tar.gz", "payload", 7)) {
    Ok(_) => test.fail("metapackage archive coordinates unexpectedly decoded")
    Err(problem) => assert "must not declare an archive payload" in problem.message
  }
}

test test_publish_conflict_and_failed_object_do_not_switch_file_index [fs, net, env, time, error] { |ctx|
  let value = publish_plan(ctx, "publish-conflict-repo")?
  let store_root = test.temp_dir(ctx, name: "publish-conflict-store")?
  stage_plan_artifacts(ctx, value, store_root)
  let snapshot = repo.snapshot(value, store_root)?
  let remote_root = test.temp_dir(ctx, name: "publish-conflict-remote")?
  let work = test.temp_dir(ctx, name: "publish-conflict-work")?
  let remote_url = f"file://{remote_root}"
  let app = node_named(value, "app")?
  let blocked_metadata = fp"{remote_root}/{pm_util.remote_metadata_rel("aarch64", app.name, app.ver, app.rel, app.artifact_key, app.proof_key)}"
  blocked_metadata.parent.mkdir()
  blocked_metadata.write("different immutable metadata")
  json.write(fp"{remote_root}/index.json", [])

  match repo.publish(snapshot, remote_url, "", work) {
    Ok(_) => test.fail("conflicting immutable metadata unexpectedly published")
    Err(problem) => assert "already exists with different bytes" in problem.message
  }

  let unchanged_index = fp"{remote_root}/index.json".read_text()?
  assert unchanged_index == "[]"
  assert fp"{remote_root}/{pm_util.remote_binary_rel("aarch64", app.name, app.ver, app.rel, app.artifact_key)}".exists()?

  let clean_remote = test.temp_dir(ctx, name: "publish-tuple-conflict-remote")?
  let clean_work = test.temp_dir(ctx, name: "publish-tuple-conflict-work")?
  let clean_url = f"file://{clean_remote}"
  repo.publish(snapshot, clean_url, "", clean_work)
  let published = fp"{clean_remote}/index.json".read_text()?
  let raw = remote.load_remote_index_from(fp"{clean_remote}/index.json")?
  fp"{clean_remote}/index.json".write(json.encode([{...raw[0], sha256: "different tuple bytes"}])? + "\n")

  repo.publish(snapshot, clean_url, "", clean_work)
  assert fp"{clean_remote}/index.json".read_text()? == published
}

test test_publish_rebuild_under_same_release_replaces_only_its_index_row [fs, net, env, time, error] { |ctx|
  let repo_root = copied_publish_repository(ctx, "publish-rebuild-repo")?
  let remote_root = test.temp_dir(ctx, name: "publish-rebuild-remote")?
  let remote_url = f"file://{remote_root}"
  let first = publish_repository_once(ctx, repo_root, remote_url, "publish-rebuild-first")?
  let before = remote.load_remote_index_from(fp"{remote_root}/index.json")?

  let recipe = fp"{repo_root}/packages/app/PKGBUILD.xsh"
  recipe.write(recipe.read_text()? + "# A rebuild input without a rel bump.\n")
  let second = publish_repository_once(ctx, repo_root, remote_url, "publish-rebuild-second")?
  let after = remote.load_remote_index_from(fp"{remote_root}/index.json")?

  let old_app = node_named(first, "app")?
  let new_app = node_named(second, "app")?
  assert old_app.artifact_key != new_app.artifact_key
  assert index_row(after, "app")?.artifact_key == new_app.artifact_key
  assert index_row(after, "app")?.rel == "1"

  for name in ["host-tool", "runtime-lib", "target-sdk"] {
    assert index_row(after, name)? == index_row(before, name)?
  }

  let old_row = index_row(before, "app")?
  let new_row = index_row(after, "app")?

  for rel in [old_row.tarball, old_row.metadata, old_row.proof, new_row.tarball, new_row.metadata, new_row.proof] {
    assert fp"{remote_root}/{rel}".exists()?
  }

  assert hash.sha256(fp"{remote_root}/{old_row.tarball}")?.hex() == old_row.sha256

  recipe.write(recipe.read_text()?.replace("# A rebuild input without a rel bump.\n", with: ""))
  let _ = publish_repository_once(ctx, repo_root, remote_url, "publish-rebuild-revert")?
  assert index_row(remote.load_remote_index_from(fp"{remote_root}/index.json")?, "app")?.artifact_key == old_app.artifact_key
}

test test_publish_refuses_a_row_behind_the_remote_release [fs, net, env, time, error] { |ctx|
  let remote_root = test.temp_dir(ctx, name: "publish-behind-remote")?
  let remote_url = f"file://{remote_root}"
  let ahead_root = copied_publish_repository(ctx, "publish-behind-ahead-repo")?
  let recipe = fp"{ahead_root}/packages/app/PKGBUILD.xsh"
  recipe.write(recipe.read_text()?.replace("export let rel = \"1\"", with: "export let rel = \"2\""))
  let _ = publish_repository_once(ctx, ahead_root, remote_url, "publish-behind-ahead")?
  let published = fp"{remote_root}/index.json".read_text()?

  let stale_root = copied_publish_repository(ctx, "publish-behind-stale-repo")?

  match publish_repository_once(ctx, stale_root, remote_url, "publish-behind-stale") {
    Ok(_) => test.fail("a release behind the remote unexpectedly published")
    Err(problem) => assert "aarch64/app 1-1 is behind remote 1-2" in problem.message
  }

  assert fp"{remote_root}/index.json".read_text()? == published
}

test test_publish_x86_64_plan_uses_its_target_arch [fs, net, env, time, error] { |ctx|
  let repo_root = copied_publish_repository(ctx, "publish-x86-repo")?
  let target = types.target_x86_64()
  let value = plan.resolve(
    catalog.load_for_target(repo_root, target)?,
    {target, index_sha256: "publish-empty-x86-remote", packages: []},
    policy.x86_64_docker(),
    ["app"],
    false,
  )?
  let store_root = test.temp_dir(ctx, name: "publish-x86-store")?
  stage_plan_artifacts(ctx, value, store_root, target:)
  let remote_root = test.temp_dir(ctx, name: "publish-x86-remote")?
  repo.publish(
    repo.snapshot(value, store_root)?,
    f"file://{remote_root}",
    "",
    test.temp_dir(ctx, name: "publish-x86-work")?,
  )

  let index = remote.load_remote_index_from(fp"{remote_root}/index.json")?
  assert [entry.name for entry in index] == ["app", "host-tool", "runtime-lib", "target-sdk"]

  for entry in index {
    let node = node_named(value, entry.name)?
    assert entry.arch == "x86_64"
    assert entry.tarball == pm_util.remote_binary_rel("x86_64", node.name, node.ver, node.rel, node.artifact_key)
      .display()
    assert entry.metadata == pm_util.remote_metadata_rel(
      "x86_64",
      node.name,
      node.ver,
      node.rel,
      node.artifact_key,
      node.proof_key,
    )
      .display()
    assert entry.proof == pm_util.remote_proof_rel(
      "x86_64",
      node.name,
      node.ver,
      node.rel,
      node.artifact_key,
      node.proof_key,
    )
      .display()
    assert fp"{remote_root}/{entry.tarball}".exists()?
    assert fp"{remote_root}/{entry.proof}".exists()?
    let metadata = json.read(fp"{remote_root}/{entry.metadata}")?.require(PublishedArchDto)?
    assert metadata.arch == "x86_64"
    assert metadata.target == "x86_64-linux-musl"
  }
}

test test_remote_decoder_preserves_legacy_fallback_and_new_identity [fs, net, env, error] { |ctx|
  let legacy = remote.decode_remote_package({
    arch: "aarch64",
    name: "legacy",
    ver: "1",
    rel: "1",
    deps: [],
    mkdeps: [],
    sha256: "payload",
    size: 1,
    tarball: "packages/aarch64/legacy/legacy-1-1.tar.gz",
    metadata: "metadata/aarch64/legacy/legacy-1-1.json",
    source_sha256: "",
    metapackage: false,
  })?
  let legacy_plan = remote.plan_artifact_from_package(legacy)?
  assert legacy.artifact_key == ""
  assert legacy_plan.artifact_key == ""
  assert legacy_plan.retrieval.metadata_sha256 != ""

  let legacy_remote = test.temp_dir(ctx, name: "publish-legacy-metadata-remote")?
  let legacy_metadata = fp"{legacy_remote}/metadata/aarch64/legacy/legacy-1-1.json"
  legacy_metadata.parent.mkdir()
  json.write(legacy_metadata, {name: "legacy", ver: "1", rel: "1"})
  let hydrated_legacy = remote.plan_artifact_from_package_at_repo(
    legacy,
    f"file://{legacy_remote}",
    test.temp_dir(ctx, name: "publish-legacy-metadata-cache")?,
  )?
  assert hydrated_legacy.retrieval.metadata_sha256 == hash.sha256(legacy_metadata)?.hex()

  let modern = remote.decode_remote_package({
    arch: "aarch64",
    name: "modern",
    ver: "1",
    rel: "1",
    deps: [],
    mkdeps_host: [],
    mkdeps_target: [],
    sha256: "payload",
    size: 1,
    tarball: "packages/aarch64/modern/modern-1-1.tar.gz",
    metadata: "metadata/aarch64/modern/modern-1-1.json",
    metadata_sha256: "metadata",
    artifact_key: "artifact",
    recipe_sha256: "recipe",
    executor_sha256: "executor",
    proof_key: "proof-key",
    proof_sha256: "proof-input",
    proof: "proofs/aarch64/modern/modern-1-1.json",
    proof_receipt_sha256: "proof-receipt",
    source_sha256: "",
    metapackage: false,
  })?
  assert modern.runtime_only_deps == []
  let modern_plan = remote.plan_artifact_from_package(modern)?
  assert modern_plan.artifact_key == "artifact"
  assert modern_plan.retrieval.metadata_sha256 == "metadata"

  let value = publish_plan(ctx, "publish-legacy-import-repo")?
  let node = node_named(value, "app")?
  let remote_root = test.temp_dir(ctx, name: "publish-legacy-import-remote")?
  let payload = fp"{remote_root}/packages/aarch64/app/app-1-1.tar.gz"
  let metadata = fp"{remote_root}/metadata/aarch64/app/app-1-1.json"
  payload.parent.mkdir()
  metadata.parent.mkdir()
  payload.write("legacy remote payload")
  json.write(metadata, {name: node.name, ver: node.ver, rel: node.rel, executor_sha256: publish_executor_sha256()})
  let imported_store = test.temp_dir(ctx, name: "publish-legacy-import-store")?
  let imported = store.import_remote(
    types.target_aarch64(),
    imported_store,
    {
      ...node,
      action: .ReuseRemote("legacy remote artifact"),
      remote: {
        arch: "aarch64",
        payload: types.RemoteArchive(
          types.RemoteArchiveCoordinates(
            tarball: payload.relative_to(remote_root).display(),
            sha256: hash.sha256(payload)?.hex(),
          ),
        ),
        metadata: metadata.relative_to(remote_root).display(),
        metadata_sha256: hash.sha256(metadata)?.hex(),
      },
    },
    f"file://{remote_root}",
    test.temp_dir(ctx, name: "publish-legacy-import-cache")?,
  )?
  assert imported.origin == .Remote
}

test test_legacy_metadata_hash_is_fetched_into_retrieval_and_enforced_on_import [fs, net, env, error] { |ctx|
  let value = publish_plan(ctx, "publish-legacy-hash-repo")?
  let node = node_named(value, "app")?
  let remote_root = test.temp_dir(ctx, name: "publish-legacy-hash-remote")?
  let payload = fp"{remote_root}/packages/aarch64/app/app-1-1.tar.gz"
  let metadata = fp"{remote_root}/metadata/aarch64/app/app-1-1.json"
  payload.parent.mkdir()
  metadata.parent.mkdir()
  payload.write("legacy hash payload")
  json.write(metadata, {name: node.name, ver: node.ver, rel: node.rel, executor_sha256: publish_executor_sha256()})
  let legacy = remote.decode_remote_package({
    arch: "aarch64",
    name: node.name,
    ver: node.ver,
    rel: node.rel,
    deps: [],
    mkdeps: [],
    sha256: hash.sha256(payload)?.hex(),
    size: payload.metadata()?.size,
    tarball: payload.relative_to(remote_root).display(),
    metadata: metadata.relative_to(remote_root).display(),
    source_sha256: "",
    metapackage: false,
  })?
  let hydrated = remote.plan_artifact_from_package_at_repo(
    legacy,
    f"file://{remote_root}",
    test.temp_dir(ctx, name: "publish-legacy-hash-cache")?,
  )?
  assert hydrated.retrieval.metadata_sha256 == hash.sha256(metadata)?.hex()

  let remote_node = {...node, action: types.ReuseRemote("legacy remote artifact"), remote: hydrated.retrieval}
  let imported = store.import_remote(
    types.target_aarch64(),
    test.temp_dir(ctx, name: "publish-legacy-hash-store")?,
    remote_node,
    f"file://{remote_root}",
    test.temp_dir(ctx, name: "publish-legacy-hash-import-cache")?,
  )?
  assert imported.metadata_sha256 == hydrated.retrieval.metadata_sha256

  metadata.write("changed legacy metadata")

  match store.import_remote(
    types.target_aarch64(),
    test.temp_dir(ctx, name: "publish-legacy-hash-corrupt-store")?,
    remote_node,
    f"file://{remote_root}",
    test.temp_dir(ctx, name: "publish-legacy-hash-corrupt-cache")?,
  ) {
    Ok(_) => test.fail("changed legacy metadata unexpectedly imported")
    Err(problem) => assert "remote metadata SHA-256 mismatch" in problem.message
  }
}

test test_publish_requires_token_only_for_network_remote [fs, net, env, time, error] { |ctx|
  let value = publish_plan(ctx, "publish-token-repo")?
  let store_root = test.temp_dir(ctx, name: "publish-token-store")?
  stage_plan_artifacts(ctx, value, store_root)
  let snapshot = repo.snapshot(value, store_root)?
  let work = test.temp_dir(ctx, name: "publish-token-work")?

  match repo.publish(snapshot, "https://example.invalid/repo", "", work) {
    Ok(_) => test.fail("network publication without a token unexpectedly succeeded")
    Err(problem) => assert "needs LAPUTA_TOKEN" in problem.message
  }
}

test test_local_mirror_publication_needs_no_token_and_sends_none [fs, net, env, time, error] { |ctx|
  let value = publish_plan(ctx, "publish-local-mirror-repo")?
  let store_root = test.temp_dir(ctx, name: "publish-local-mirror-store")?
  stage_plan_artifacts(ctx, value, store_root)
  let snapshot = repo.snapshot(value, store_root)?
  let work = test.temp_dir(ctx, name: "publish-local-mirror-work")?
  let local_mirror = "http://127.0.0.1:3000"
  let response_headers: List[NetHeader] = []
  let created = {
    status: 201,
    reason: "Created",
    bytes: 0,
    headers: response_headers,
    url: local_mirror,
    effective_url: local_mirror,
    redirect_count: 0,
  }
  let missing_index: NetResponse = {
    status: 404,
    reason: "Not Found",
    bytes: 0,
    headers: [],
    url: f"{local_mirror}/index.json",
    effective_url: f"{local_mirror}/index.json",
    redirect_count: 0,
    body: b"",
  }
  test.mock(
    ctx,
    "net.request",
    {url: f"{local_mirror}/index.json"},
    Ok(missing_index),
  )
  test.mock(ctx, "net.upload", {method: "PUT"}, Ok(created), snapshot.packages.len() * 3 + 1)

  repo.publish(snapshot, local_mirror, "", work)

  let uploads = test.calls(ctx, "net.upload")
  assert uploads.len() == snapshot.packages.len() * 3 + 1

  for upload in uploads {
    let headers = upload.args.get("headers")?.require(List[NetHeader])?
    assert [header.name for header in headers if header.name == "Authorization"] == []
  }
}
