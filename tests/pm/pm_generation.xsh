##! Behavior coverage for runtime-pure system generation plans and verified overlay composition.
use pm.catalog
use pm.generation
use pm.plan
use pm.policy
use pm.store
use pm.types

pure fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/{name}"
}

pure generation_empty_remote() -> types.RemoteSnapshot {
  {target: types.Aarch64LinuxMusl, index_sha256: "generation-empty-remote", packages: []}
}

pure test_generation_sha256(value: Str) -> Str {
  bytes.from_text(value).sha256().hex()
}

proc copied_generation_repository(ctx: TestContext, name: Str) [fs, env, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name:)?
  let _ = fs.copy_tree(fixture("graph-catalog/packages"), fp"{root}/packages", parents: true, overwrite: true)?
  fp"{root}/pm".mkdir()
  p"pm/proof.xsh".copy(fp"{root}/pm/proof.xsh", overwrite: true)
  root
}

proc generation_build_plan(ctx: TestContext, name: Str) -> Result[types.BuildPlan] {
  let repo_root = copied_generation_repository(ctx, name)?
  plan.resolve(
    catalog.load(repo_root)?,
    generation_empty_remote(),
    policy.aarch64_docker(),
    ["app"],
    false,
  )?
}

proc generation_baselayout_build_plan(ctx: TestContext, name: Str) -> Result[types.BuildPlan] {
  let repo_root = copied_generation_repository(ctx, name)?
  let _ = fs.copy_tree(
    fixture("generation-overlay/baselayout"),
    fp"{repo_root}/packages/baselayout",
    parents: true,
    overwrite: true,
  )?
  plan.resolve(
    catalog.load(repo_root)?,
    generation_empty_remote(),
    policy.aarch64_docker(),
    ["baselayout"],
    false,
  )?
}

proc stage_generation_artifacts(ctx: TestContext, value: types.BuildPlan, store_root: Path) {
  let executor_sha256 = bytes.from_text("test executor").sha256().hex()

  for node in value.nodes {
    let stage = test.temp_dir(ctx, name: f"generation-stage-{node.name}")?
    let contents = fp"{stage}/contents"
    let payload = fp"{stage}/payload.tar.gz"
    let metadata = fp"{stage}/metadata.json"
    let proof = fp"{stage}/proof.json"
    let path_value = fp"{contents}/usr/share/{node.name}"
    path_value.parent.mkdir()
    path_value.write(f"payload {node.name}\n")
    archive.tar_create(payload, contents, [p"."], compression: "gz")
    json.write(
      metadata,
      {
        arch: types.pm_target_arch(value.target),
        name: node.name,
        ver: node.ver,
        rel: node.rel,
        package_kind: "payload",
        files: [
          {
            path: f"usr/share/{node.name}",
            kind: "file",
            mode: 0o644,
            sha256: test_generation_sha256(f"payload {node.name}\n"),
            target: "",
          },
        ],
      },
    )
    proof.write(f"proof {node.name}\n")
    let _ = store.commit(
      value.target,
      store_root,
      node,
      {payload, payload_sha256: hash.sha256(payload)?.hex(), metadata, proof, executor_sha256},
    )?
  }
}

proc stage_generation_baselayout_artifact(ctx: TestContext, value: types.BuildPlan, store_root: Path) {
  let node = value.nodes[0]
  let executor_sha256 = bytes.from_text("test executor").sha256().hex()
  let stage = test.temp_dir(ctx, name: "generation-stage-baselayout")?
  let contents = fp"{stage}/contents"
  let payload = fp"{stage}/payload.tar.gz"
  let metadata = fp"{stage}/metadata.json"
  let proof = fp"{stage}/proof.json"
  let init_directory = fp"{contents}/usr/lib/init/rc.d"
  init_directory.mkdir()
  init_directory.chmod(0o755)
  archive.tar_create(payload, contents, [p"."], compression: "gz")
  json.write(
    metadata,
    {
      arch: types.pm_target_arch(value.target),
      name: node.name,
      ver: node.ver,
      rel: node.rel,
      package_kind: "payload",
      files: [
        {
          path: "usr/lib/init/rc.d",
          kind: "tree",
          mode: 0o755,
          sha256: "",
          target: "",
        },
      ],
    },
  )
  proof.write("proof baselayout\n")
  let _ = store.commit(
    value.target,
    store_root,
    node,
    {payload, payload_sha256: hash.sha256(payload)?.hex(), metadata, proof, executor_sha256},
  )?
}

proc empty_overlay(ctx: TestContext, name: Str) -> Result[Path] {
  let overlay = test.temp_dir(ctx, name:)?
  fp"{overlay}/overlay".mkdir()
  fp"{overlay}/overlay"
}

proc expect_generation_error(ctx: TestContext, result: Result[types.GenerationReceipt], expected: Str) {
  match result {
    Ok(_) => test.fail(f"{expected}: generation unexpectedly succeeded")
    Err(problem) => assert expected in problem.message
  }
}

test test_generation_runtime_closure_excludes_build_toolchain [fs, env, error] { |ctx|
  let build_value = generation_build_plan(ctx, "generation-runtime-plan")?
  let overlay = empty_overlay(ctx, "generation-runtime-overlay")?
  let value = generation.plan(build_value, ["app"], generation.overlay_digest(overlay)?)?
  assert value.runtime_roots == ["app"]
  assert [artifact.package_name for artifact in value.artifacts] == ["app", "runtime-lib"]

  let store_root = test.temp_dir(ctx, name: "generation-runtime-store")?
  stage_generation_artifacts(ctx, build_value, store_root)
  let output = fp"{test.temp_dir(ctx, name: "generation-runtime-output")?}/root"
  let receipt = generation.compose(value, store_root, output, overlay)?
  assert [artifact.package_name for artifact in receipt.artifacts] == ["app", "runtime-lib"]
  assert fp"{output}/usr/share/app".read_text()? == "payload app\n"
  assert fp"{output}/usr/share/runtime-lib".read_text()? == "payload runtime-lib\n"
  assert fp"{output}/usr/share/host-tool".exists()? == false
  assert fp"{output}/usr/share/target-sdk".exists()? == false
  generation.verify_generation(output, receipt)
}

test test_generation_x86_64_plan_and_composition_preserve_target [fs, env, error] { |ctx|
  let target = types.target_x86_64()
  let repo_root = copied_generation_repository(ctx, "generation-x86-plan")?
  let build_value = plan.resolve(
    catalog.load_for_target(repo_root, target)?,
    {...generation_empty_remote(), target},
    policy.x86_64_docker(),
    ["app"],
    false,
  )?
  let overlay = empty_overlay(ctx, "generation-x86-overlay")?
  let planned = generation.plan(build_value, ["app"], generation.overlay_digest(overlay)?)?
  assert types.target_text(planned.target) == "x86_64-linux-musl"
  let plan_path = test.temp_path(ctx, name: "generation-x86-plan.json")
  generation.write_generation_plan(plan_path, planned)
  assert generation.read_generation_plan(plan_path)? == planned

  let store_root = test.temp_dir(ctx, name: "generation-x86-store")?
  stage_generation_artifacts(ctx, build_value, store_root)
  let output = fp"{test.temp_dir(ctx, name: "generation-x86-output")?}/root"
  let receipt = generation.compose(planned, store_root, output, overlay)?
  assert types.target_text(receipt.target) == "x86_64-linux-musl"
  assert generation.read_generation_receipt(output)? == receipt
  generation.verify_generation(output, receipt)
}

test test_generation_plan_and_receipt_are_deterministic_for_root_order_and_duplicates [fs, env, error] { |ctx|
  let build_value = generation_build_plan(ctx, "generation-deterministic-plan")?
  let overlay = empty_overlay(ctx, "generation-deterministic-overlay")?
  let overlay_sha256 = generation.overlay_digest(overlay)?
  let first = generation.plan(build_value, ["runtime-lib", "app", "app"], overlay_sha256)?
  let second = generation.plan(build_value, ["app", "runtime-lib"], overlay_sha256)?
  assert first == second
  assert first.runtime_roots == ["app", "runtime-lib"]

  let store_root = test.temp_dir(ctx, name: "generation-deterministic-store")?
  stage_generation_artifacts(ctx, build_value, store_root)
  let first_output = fp"{test.temp_dir(ctx, name: "generation-deterministic-first")?}/root"
  let second_output = fp"{test.temp_dir(ctx, name: "generation-deterministic-second")?}/root"
  assert generation.compose(first, store_root, first_output, overlay)? == generation.compose(
    second,
    store_root,
    second_output,
    overlay,
  )?
}

test test_generation_plan_json_round_trips_and_rejects_changed_identity [fs, env, error] { |ctx|
  let build_value = generation_build_plan(ctx, "generation-plan-json")?
  let overlay = empty_overlay(ctx, "generation-plan-json-overlay")?
  let planned = generation.plan_profile(
    build_value,
    ["app"],
    {name: "qemu-dwl-foot", overlay_sha256: generation.overlay_digest(overlay)?, replacements: []},
  )?
  let path_value = test.temp_path(ctx, name: "generation-plan.json")
  generation.write_generation_plan(path_value, planned)
  assert generation.read_generation_plan(path_value)? == planned

  let dto = json.read(path_value)?.require(generation.GenerationPlanDto)?
  json.write(
    path_value,
    {...dto, generation_sha256: "0000000000000000000000000000000000000000000000000000000000000000"},
  )
  match generation.read_generation_plan(path_value) {
    Ok(_) => test.fail("changed generation plan digest was accepted")
    Err(problem) => assert "digest does not match" in problem.message
  }
}

test test_generation_rejects_missing_and_corrupt_runtime_artifacts_before_mutation [fs, env, error] { |ctx|
  let build_value = generation_build_plan(ctx, "generation-invalid-plan")?
  let overlay = empty_overlay(ctx, "generation-invalid-overlay")?
  let value = generation.plan(build_value, ["app"], generation.overlay_digest(overlay)?)?
  let missing_store = test.temp_dir(ctx, name: "generation-missing-store")?
  let missing_output = fp"{test.temp_dir(ctx, name: "generation-missing-output")?}/root"
  expect_generation_error(ctx, generation.compose(value, missing_store, missing_output, overlay), "is missing")
  assert missing_output.exists()? == false

  let corrupt_store = test.temp_dir(ctx, name: "generation-corrupt-store")?
  stage_generation_artifacts(ctx, build_value, corrupt_store)
  let app = value.artifacts[0]
  fp"{store.artifact_path(corrupt_store, app.artifact_key)}/payload.tar.gz".write("corrupt payload")
  let corrupt_output = fp"{test.temp_dir(ctx, name: "generation-corrupt-output")?}/root"
  expect_generation_error(
    ctx,
    generation.compose(value, corrupt_store, corrupt_output, overlay),
    "payload SHA-256 does not match receipt",
  )
  assert corrupt_output.exists()? == false
}

test test_generation_profile_overlay_metadata_and_explicit_replacement [fs, env, error] { |ctx|
  let build_value = generation_build_plan(ctx, "generation-overlay-plan")?
  let store_root = test.temp_dir(ctx, name: "generation-overlay-store")?
  stage_generation_artifacts(ctx, build_value, store_root)
  let overlay = empty_overlay(ctx, "generation-overlay-root")?
  fp"{overlay}/etc".mkdir()
  fp"{overlay}/etc/profile".write("profile configuration\n")
  json.write(
    fp"{overlay}/overlay.json",
    {format: "laputa-generation-overlay-1", profile: "qemu-dwl-foot", replacements: []},
  )
  let profile = generation.overlay_profile(overlay)?
  let value = generation.plan_profile(build_value, ["app"], profile)?
  let output = fp"{test.temp_dir(ctx, name: "generation-overlay-output")?}/root"
  let receipt = generation.compose(value, store_root, output, overlay)?
  assert receipt.profile.name == "qemu-dwl-foot"
  assert fp"{output}/etc/profile".read_text()? == "profile configuration\n"
  assert fp"{output}/overlay.json".exists()? == false

  let conflict_overlay = empty_overlay(ctx, "generation-conflict-overlay")?
  fp"{conflict_overlay}/usr/share".mkdir()
  fp"{conflict_overlay}/usr/share/app".write("replaced app\n")
  let conflict = generation.plan(build_value, ["app"], generation.overlay_digest(conflict_overlay)?)?
  let conflict_output = fp"{test.temp_dir(ctx, name: "generation-conflict-output")?}/root"
  expect_generation_error(
    ctx,
    generation.compose(conflict, store_root, conflict_output, conflict_overlay),
    "conflicts with package app",
  )
  assert conflict_output.exists()? == false

  json.write(
    fp"{conflict_overlay}/overlay.json",
    {
      format: "laputa-generation-overlay-1",
      profile: "qemu-dwl-foot",
      replacements: ["usr/share/app"],
    },
  )
  let replacement_profile = generation.overlay_profile(conflict_overlay)?
  let replacement = generation.plan_profile(build_value, ["app"], replacement_profile)?
  let replacement_output = fp"{test.temp_dir(ctx, name: "generation-replacement-output")?}/root"
  let _ = generation.compose(replacement, store_root, replacement_output, conflict_overlay)?
  assert fp"{replacement_output}/usr/share/app".read_text()? == "replaced app\n"
}

test test_generation_overlay_coalesces_matching_baselayout_directory_and_rejects_conflicts [fs, env, error] { |ctx|
  let build_value = generation_baselayout_build_plan(ctx, "generation-baselayout-plan")?
  let store_root = test.temp_dir(ctx, name: "generation-baselayout-store")?
  stage_generation_baselayout_artifact(ctx, build_value, store_root)

  # The profile owns a new hook below baselayout's directory.  Its matching
  # directory declaration is structural, not a package replacement; the
  # profile's overlay digest remains explicit receipt provenance.
  let overlay = empty_overlay(ctx, "generation-baselayout-overlay")?
  let hook_directory = fp"{overlay}/usr/lib/init/rc.d"
  hook_directory.mkdir()
  hook_directory.chmod(0o755)
  fp"{hook_directory}/laputa-test.boot".write("profile hook\n")
  let profile = generation.overlay_profile(overlay)?
  let value = generation.plan_profile(build_value, ["baselayout"], profile)?
  let output = fp"{test.temp_dir(ctx, name: "generation-baselayout-output")?}/root"
  let receipt = generation.compose(value, store_root, output, overlay)?
  assert receipt.profile.overlay_sha256 == generation.overlay_digest(overlay)?
  assert fp"{output}/usr/lib/init/rc.d/laputa-test.boot".read_text()? == "profile hook\n"
  generation.verify_generation(output, receipt)

  let file_conflict = empty_overlay(ctx, "generation-baselayout-file-conflict")?
  fp"{file_conflict}/usr/lib/init".mkdir()
  fp"{file_conflict}/usr/lib/init/rc.d".write("not a directory\n")
  let file_plan = generation.plan(build_value, ["baselayout"], generation.overlay_digest(file_conflict)?)?
  let file_output = fp"{test.temp_dir(ctx, name: "generation-baselayout-file-output")?}/root"
  expect_generation_error(
    ctx,
    generation.compose(file_plan, store_root, file_output, file_conflict),
    "incompatible directory type or mode metadata",
  )
  assert file_output.exists()? == false

  let mode_conflict = empty_overlay(ctx, "generation-baselayout-mode-conflict")?
  let mode_directory = fp"{mode_conflict}/usr/lib/init/rc.d"
  mode_directory.mkdir()
  mode_directory.chmod(0o700)
  let mode_plan = generation.plan(build_value, ["baselayout"], generation.overlay_digest(mode_conflict)?)?
  let mode_output = fp"{test.temp_dir(ctx, name: "generation-baselayout-mode-output")?}/root"
  expect_generation_error(
    ctx,
    generation.compose(mode_plan, store_root, mode_output, mode_conflict),
    "incompatible directory type or mode metadata",
  )
  assert mode_output.exists()? == false
}

# Artifact keys exclude the executor, so a package can be rebuilt under the
# same ver-rel. The generation follows the artifact key, not the tuple: the
# rebuilt package yields a new generation (and so a new system bundle).
test test_generation_follows_artifact_keys_not_releases [fs, env, error] { |ctx|
  let first = generation_build_plan(ctx, "generation-key-first")?
  # A separate checkout: one process loads each recipe path once.
  let repo_root = copied_generation_repository(ctx, "generation-key-rebuilt")?
  let recipe = fp"{repo_root}/packages/runtime-lib/PKGBUILD.xsh"
  recipe.write(recipe.read_text()? + "# A rebuild input without a rel bump.\n")
  let rebuilt = plan.resolve(
    catalog.load(repo_root)?,
    generation_empty_remote(),
    policy.aarch64_docker(),
    ["app"],
    false,
  )?

  let before = generation.plan(first, ["app"], test_generation_sha256("overlay"))?
  let after = generation.plan(rebuilt, ["app"], test_generation_sha256("overlay"))?
  assert [artifact.package_id for artifact in after.artifacts] == [artifact.package_id for artifact in before.artifacts]
  assert after.generation_sha256 != before.generation_sha256

  let before_keys = {artifact.package_name: artifact.artifact_key for artifact in before.artifacts}
  let changed = [
    artifact.package_name
    for artifact in after.artifacts
    if before_keys.get(artifact.package_name)? != artifact.artifact_key
  ]
  # runtime-lib and app, which builds against it.
  assert changed == ["app", "runtime-lib"]
}
