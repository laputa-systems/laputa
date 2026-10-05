##! Behavior coverage for immutable package artifact-store publication and verification.
use pm.store
use pm.types

type TestStage = {root: Path, staged: types.StagedArtifact}

type ReceiptDto = {
  format: Str,
  key: Str,
  target: Str,
  package_name: Str,
  package_id: Str,
  origin: Str,
  recipe_sha256: Str,
  executor_sha256: Str,
  payload_sha256: Str,
  metadata_sha256: Str,
  proof_key: Str,
  proof_sha256: Str,
  dependency_keys: List[Str],
  runtime_dependency_keys: List[Str],
}

pure digest(value: Str) -> Str {
  bytes.from_text(value).sha256().hex()
}

pure test_node(key: Str) -> types.PlanNode {
  {
    name: "demo",
    ver: "1.0.0",
    rel: "1",
    package_id: "demo-1.0.0-1",
    recipe_dir: p"packages/demo",
    recipe_sha256: digest("recipe"),
    proof_sha256: digest("proof-input"),
    artifact_key: key,
    proof_key: digest("proof-key"),
    action: .Build("test build"),
    level: 0,
    dependencies: [],
    remote: null,
  }
}

pure node_with_shared_runtime_and_build_host_dependency(
  key: Str,
  dependency_key: Str,
  build_host_first: Bool = false,
) -> types.PlanNode {
  let runtime: types.PlanDependency = types.PlanDependency(
    name: "llvm-toolchain",
    kind: types.dependency_runtime(),
    artifact_key: dependency_key,
  )
  let build_host: types.PlanDependency = types.PlanDependency(
    name: "llvm-toolchain",
    kind: types.dependency_build_host(),
    artifact_key: dependency_key,
  )

  {
    ...test_node(key),
    dependencies: if build_host_first { [build_host, runtime] } else { [runtime, build_host] },
  }
}

proc staged_artifact(
  ctx: TestContext,
  name: Str,
  payload: Str = "payload",
  metadata: Str = "metadata",
  proof: Str = "proof",
) -> Result[TestStage] {
  let root = test.temp_dir(ctx, name:)?
  let payload_path = fp"{root}/payload.tar.gz"
  let metadata_path = fp"{root}/metadata.json"
  let proof_path = fp"{root}/proof.json"
  payload_path.write(payload)
  metadata_path.write(metadata)
  proof_path.write(proof)
  {
    root,
    staged: {
      payload: payload_path,
      payload_sha256: digest(payload),
      metadata: metadata_path,
      proof: proof_path,
      executor_sha256: digest("executor"),
    },
  }
}

proc store_root(ctx: TestContext, name: Str) [fs, error] -> Result[Path] {
  test.temp_dir(ctx, name:)
}

proc expect_store_error(_: TestContext, result: Result[types.ArtifactReceipt], expected: Str) {
  match result {
    Ok(_) => test.fail(f"{expected}: operation unexpectedly succeeded")
    Err(problem) => assert expected in problem.message
  }
}

test test_store_rejects_missing_and_invalid_keys [fs, error] { |ctx|
  let root = store_root(ctx, "store-missing")?
  let key = digest("missing")
  expect_store_error(ctx, store.lookup(root, key), "is missing")
  expect_store_error(ctx, store.lookup(root, "../not-a-key"), "artifact key must be a lowercase SHA-256 digest")
}

test test_store_commits_atomically_and_reuses_exact_artifact [fs, error] { |ctx|
  let root = store_root(ctx, "store-commit")?
  let key = digest("commit")
  let first_stage = staged_artifact(ctx, "store-commit-first", payload: "first payload")?
  let first = store.commit(types.target_aarch64(), root, test_node(key), first_stage.staged)?
  let final_dir = store.artifact_path(root, key)
  assert first.origin == .Built
  assert first.key == key
  assert fp"{final_dir}/artifact.json".exists()?
  assert store.lookup(root, key)? == first

  let replacement = staged_artifact(ctx, "store-commit-replacement", payload: "replacement payload")?
  let reused = store.commit(types.target_aarch64(), root, test_node(key), replacement.staged)?
  assert reused == first
  assert fp"{final_dir}/payload.tar.gz".read_text()? == "first payload"
}

test test_store_receipt_preserves_x86_64_target [fs, error] { |ctx|
  let root = store_root(ctx, "store-x86-target")?
  let key = digest("x86-target")
  let stage = staged_artifact(ctx, "store-x86-target-stage")?
  let receipt = store.commit(types.target_x86_64(), root, test_node(key), stage.staged)?

  assert types.target_text(receipt.target) == "x86_64-linux-musl"
  assert types.target_text(store.lookup(root, key)?.target) == "x86_64-linux-musl"

  match store.commit(types.target_aarch64(), root, test_node(key), stage.staged) {
    Ok(_) => test.fail("artifact key was reused across targets")
    Err(problem) => assert "target does not match requested aarch64-linux-musl" in problem.message
  }
}

test test_store_receipts_deduplicate_shared_runtime_and_build_host_artifacts [fs, error] { |ctx|
  let root = store_root(ctx, "store-shared-edge")?
  let key = digest("shared-edge-artifact")
  let dependency_key = digest("shared-edge-dependency")
  let runtime_first = node_with_shared_runtime_and_build_host_dependency(key, dependency_key)
  let build_host_first = node_with_shared_runtime_and_build_host_dependency(key, dependency_key, true)

  # Edge order and kind stay in PlanNode; receipt lists are canonical artifact identities.
  assert store.receipt_dependency_keys(runtime_first) == [dependency_key]
  assert store.receipt_dependency_keys(build_host_first) == [dependency_key]
  assert store.receipt_runtime_dependency_keys(runtime_first) == [dependency_key]
  assert store.receipt_runtime_dependency_keys(build_host_first) == [dependency_key]

  let receipt = store.commit(
    types.target_aarch64(),
    root,
    runtime_first,
    staged_artifact(ctx, "store-shared-edge-stage")?.staged,
  )?
  assert receipt.dependency_keys == [dependency_key]
  assert receipt.runtime_dependency_keys == [dependency_key]

  let final_dir = store.artifact_path(root, key)
  let raw = json.read(fp"{final_dir}/artifact.json")?.require(ReceiptDto)?
  fp"{final_dir}/artifact.json".write(
    json.encode({...raw, dependency_keys: [dependency_key, dependency_key]})? + "\n",
  )
  expect_store_error(ctx, store.verify_artifact(root, key), "repeats dependency key")
}

test test_store_discards_incomplete_temporary_artifacts [fs, error] { |ctx|
  let root = store_root(ctx, "store-temporary")?
  let key = digest("temporary")
  let temporary = fp"{root}/v2/tmp/{key}"
  temporary.mkdir()
  fp"{temporary}/payload.tar.gz".write("incomplete")
  let receipt = store.commit(
    types.target_aarch64(),
    root,
    test_node(key),
    staged_artifact(ctx, "store-temporary-stage")?.staged,
  )?
  assert receipt.key == key
  assert temporary.exists()? == false
}

test test_store_verify_all_ignores_temporary_state_and_checks_finals [fs, error] { |ctx|
  let root = store_root(ctx, "store-verify-all")?
  let key = digest("verify-all")
  let receipt = store.commit(
    types.target_aarch64(),
    root,
    test_node(key),
    staged_artifact(ctx, "store-verify-all-stage")?.staged,
  )?
  let temporary = fp"{root}/v2/tmp/{digest("ignored")}"
  temporary.mkdir()
  fp"{temporary}/partial".write("interrupted")

  test.eq(store.verify_all(root)?, [receipt])
}

test test_store_serializes_duplicate_concurrent_commits [fs, process, env, error] { |ctx|
  let root = store_root(ctx, "store-concurrent")?
  let key = digest("concurrent")
  let stage = staged_artifact(ctx, "store-concurrent-stage")?
  let script = fp"{test.temp_dir(ctx, name: "store-concurrent-script")?}/commit.xsh"
  script.write(
    r"""use pm.store
use pm.types

pure digest(value: Str) -> Str {
  bytes.from_text(value).sha256().hex()
}

proc main(...argv: List[Str]) [fs, error] {
  let node: types.PlanNode = {
    name: "demo",
    ver: "1.0.0",
    rel: "1",
    package_id: "demo-1.0.0-1",
    recipe_dir: p"packages/demo",
    recipe_sha256: digest("recipe"),
    proof_sha256: digest("proof-input"),
    artifact_key: argv[1],
    proof_key: digest("proof-key"),
    action: types.Build("concurrent test build"),
    level: 0,
    dependencies: [],
    remote: null,
  }
  let _ = store.commit(
    types.target_aarch64(),
    fp"{argv[0]}",
    node,
    {payload: fp"{argv[2]}", payload_sha256: hash.sha256(fp"{argv[2]}")?.hex(), metadata: fp"{argv[3]}", proof: fp"{argv[4]}", executor_sha256: digest("executor")},
  )?
}

main(@args)?
""",
  )
  let configured = e"XSH_HOST" ?? ""
  let runner = if configured != "" { fp"{configured}" } else { process.which("xsh")? }
  let first = spawn run $runner $script $root $key ${stage.staged.payload} ${stage.staged.metadata} \
    ${stage.staged.proof} ?
  let second = spawn run $runner $script $root $key ${stage.staged.payload} ${stage.staged.metadata} \
    ${stage.staged.proof} ?
  let statuses = wait [first, second]?
  assert statuses[0].ok
  assert statuses[1].ok
  assert store.lookup(root, key)?.key == key
}

test test_store_detects_payload_receipt_and_key_corruption [fs, error] { |ctx|
  let root = store_root(ctx, "store-corrupt")?
  let key = digest("corrupt")
  let final_dir = store.artifact_path(root, key)
  let stage = staged_artifact(ctx, "store-corrupt-stage")?
  let committed = store.commit(types.target_aarch64(), root, test_node(key), stage.staged)?

  # Lookups trust the hashes recorded at commit; explicit verification re-hashes.
  fp"{final_dir}/payload.tar.gz".write("corrupted payload")
  assert store.lookup(root, key)? == committed
  expect_store_error(ctx, store.verify_artifact(root, key), "payload SHA-256 does not match receipt")

  fp"{final_dir}/payload.tar.gz".write("payload")
  fp"{final_dir}/artifact.json".write("not JSON")
  expect_store_error(ctx, store.verify_artifact(root, key), "invalid JSON")

  let clean_root = store_root(ctx, "store-key-corrupt")?
  let clean_dir = store.artifact_path(clean_root, key)
  let _ = store.commit(
    types.target_aarch64(),
    clean_root,
    test_node(key),
    staged_artifact(ctx, "store-key-corrupt-stage")?.staged,
  )?
  let raw = json.read(fp"{clean_dir}/artifact.json")?.require(ReceiptDto)?
  fp"{clean_dir}/artifact.json".write(json.encode({...raw, key: digest("other key")})? + "\n")
  expect_store_error(ctx, store.verify_artifact(clean_root, key), "does not match")
}

test test_store_staging_failure_never_publishes_final [fs, error] { |ctx|
  let root = store_root(ctx, "store-staging-failure")?
  let key = digest("staging-failure")
  let stage = staged_artifact(ctx, "store-staging-failure-stage")?
  let broken = {...stage.staged, payload: fp"{stage.root}/missing-payload.tar.gz"}
  expect_store_error(ctx, store.commit(types.target_aarch64(), root, test_node(key), broken), "No such file")
  assert store.artifact_path(root, key).exists()? == false
}

pure remote_node(key: Str, payload: Str, metadata: Str) -> types.PlanNode {
  {
    ...test_node(key),
    action: .ReuseRemote("exact remote artifact"),
    remote: {
      arch: "aarch64",
      tarball: "packages/aarch64/demo/demo-1.0.0-1.tar.gz",
      tarball_sha256: digest(payload),
      metadata: "metadata/aarch64/demo/demo-1.0.0-1.json",
      metadata_sha256: digest(metadata),
    },
  }
}

proc remote_fixture(ctx: TestContext, name: Str, payload: Str, metadata: Str) -> Result[Path] {
  let root = test.temp_dir(ctx, name:)?
  let tarball = fp"{root}/packages/aarch64/demo/demo-1.0.0-1.tar.gz"
  let metadata_path = fp"{root}/metadata/aarch64/demo/demo-1.0.0-1.json"
  tarball.parent.mkdir()
  metadata_path.parent.mkdir()
  tarball.write(payload)
  metadata_path.write(metadata)
  root
}

test test_store_imports_verified_remote_artifact [fs, net, error] { |ctx|
  let payload = "remote payload"
  let metadata = json.encode({name: "demo", ver: "1.0.0", rel: "1", executor_sha256: digest("remote executor")})?
  let remote_root = remote_fixture(ctx, "store-remote", payload, metadata)?
  let root = store_root(ctx, "store-remote-local")?
  let key = digest("remote")
  let receipt = store.import_remote(
    types.target_aarch64(),
    root,
    remote_node(key, payload, metadata),
    f"file://{remote_root}",
    test.temp_dir(ctx, name: "store-remote-cache")?,
  )?
  assert receipt.origin == .Remote
  assert receipt.payload_sha256 == digest(payload)
  assert store.verify_artifact(root, key)? == receipt
}

test test_store_rejects_remote_hash_and_metadata_mismatches [fs, net, error] { |ctx|
  let payload = "actual remote payload"
  let metadata = json.encode({name: "demo", ver: "1.0.0", rel: "1", executor_sha256: digest("remote executor")})?
  let remote_root = remote_fixture(ctx, "store-remote-mismatch", payload, metadata)?
  let repo = f"file://{remote_root}"
  let root = store_root(ctx, "store-remote-hash-local")?
  let key = digest("remote-hash-mismatch")
  let bad_hash_node = remote_node(key, "different expected payload", metadata)
  expect_store_error(
    ctx,
    store.import_remote(
      types.target_aarch64(),
      root,
      bad_hash_node,
      repo,
      test.temp_dir(ctx, name: "store-remote-hash-cache")?,
    ),
    "payload SHA-256 mismatch",
  )
  assert store.artifact_path(root, key).exists()? == false

  let bad_metadata = json.encode({name: "not-demo", ver: "1.0.0", rel: "1", executor_sha256: digest("remote executor")})?
  let metadata_remote = remote_fixture(ctx, "store-remote-metadata", payload, bad_metadata)?
  let metadata_key = digest("remote-metadata-mismatch")
  expect_store_error(
    ctx,
    store.import_remote(
      types.target_aarch64(),
      root,
      remote_node(metadata_key, payload, bad_metadata),
      f"file://{metadata_remote}",
      test.temp_dir(ctx, name: "store-remote-metadata-cache")?,
    ),
    "remote metadata does not match plan node",
  )
  assert store.artifact_path(root, metadata_key).exists()? == false
}

test test_store_rejects_receipts_of_another_schema_and_ignores_older_layouts [fs, error] { |ctx|
  let root = store_root(ctx, "store-schema")?
  let key = digest("schema")
  let receipt = store.commit(
    types.target_aarch64(),
    root,
    test_node(key),
    staged_artifact(ctx, "store-schema-stage")?.staged,
  )?
  assert receipt.format == store.receipt_format

  let final_dir = store.artifact_path(root, key)
  let raw = json.read(fp"{final_dir}/artifact.json")?.require(ReceiptDto)?
  fp"{final_dir}/artifact.json".write(json.encode({...raw, format: "laputa-package-artifact-1"})? + "\n")
  expect_store_error(
    ctx,
    store.lookup(root, key),
    f"unsupported receipt format laputa-package-artifact-1; this PM reads {store.receipt_format}",
  )

  # Artifacts under an older layout directory are never read or listed.
  let legacy_root = store_root(ctx, "store-legacy-layout")?
  let legacy_dir = fp"{legacy_root}/v1/sha256/{key}"
  legacy_dir.mkdir()
  fp"{legacy_dir}/artifact.json".write(json.encode({...raw, format: "laputa-package-artifact-1"})? + "\n")
  expect_store_error(ctx, store.lookup(legacy_root, key), "is missing")
  test.eq(store.verify_all(legacy_root)?, [])
}

# Garbage collection keeps exactly the artifacts the kept plans name, with
# their re-proof receipts, and removes the rest with their leftover state.
test test_store_gc_keeps_named_artifacts_and_removes_the_rest [fs, error] { |ctx|
  let root = store_root(ctx, "store-gc")?
  let kept = digest("gc-kept")
  let dropped = digest("gc-dropped")
  let _ = store.commit(types.target_aarch64(), root, test_node(kept), staged_artifact(ctx, "store-gc-kept")?.staged)?
  let _ = store.commit(
    types.target_aarch64(),
    root,
    test_node(dropped),
    staged_artifact(ctx, "store-gc-dropped")?.staged,
  )?
  let kept_reproof = store.reproof_receipt_path(root, kept, digest("gc-kept-proof"))
  let dropped_reproof = store.reproof_receipt_path(root, dropped, digest("gc-dropped-proof"))
  kept_reproof.parent.mkdir()
  kept_reproof.write("{}")
  dropped_reproof.parent.mkdir()
  dropped_reproof.write("{}")
  fp"{root}/v2/tmp/{digest("gc-interrupted")}".mkdir()

  let removed = store.gc(root, [kept])?
  assert removed.artifacts == 1
  assert store.artifact_path(root, kept).exists()?
  assert ! store.artifact_path(root, dropped).exists()?
  assert kept_reproof.exists()?
  assert ! dropped_reproof.parent.exists()?
  assert fs.children(fp"{root}/v2/tmp")?.collect().is_empty()
  test.eq(store.verify_all(root)?.len(), 1)
}
