##! Behavior coverage for package fingerprints, artifact keys, and build-plan resolution.
use pm.catalog
use pm.fingerprint
use pm.plan
use pm.plan_json
use pm.policy
use pm.recipe
use pm.types

pure fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/{name}"
}

proc copied_package(ctx: TestContext, name: Str) -> Result[types.Package] {
  let dir = test.temp_dir(ctx, name:)?
  let _ = fs.copy_tree(fixture("fingerprint-package"), dir, parents: true, overwrite: true)?
  recipe.load_package(dir)?
}

proc copied_executor(ctx: TestContext) -> Result[Path] {
  let root = test.temp_dir(ctx, name: "fingerprint-executor")?
  let _ = fs.copy_tree(fixture("fingerprint-executor"), root, parents: true, overwrite: true)?
  root
}

proc build_input(pkg: types.Package) -> Result[Str] {
  fingerprint.package_build_input(p".", pkg, types.Aarch64LinuxMusl)?
}

test test_package_build_fingerprint_is_repeatable_and_ignores_mtime [fs, env, error] { |ctx|
  let pkg = copied_package(ctx, "fingerprint-repeat")?
  let first = build_input(pkg)?
  assert build_input(pkg)? == first
  let helper = fp"{pkg.dir}/helper.xsh"
  helper.write(helper.read_text()?)
  assert build_input(pkg)? == first
}

# Git records only whether a checkout file is executable, so the other mode
# bits a clone gets (umask group-write, setgid inherited from a parent
# directory) are host noise that must not change a key.
test test_package_build_fingerprint_follows_only_the_checkout_executable_bit [fs, env, error] { |ctx|
  let pkg = copied_package(ctx, "fingerprint-checkout-modes")?
  let first = build_input(pkg)?
  fp"{pkg.dir}/files".chmod(0o2775)
  fp"{pkg.dir}/files/input.txt".chmod(0o664)
  assert build_input(pkg)? == first
  fp"{pkg.dir}/files/input.txt".chmod(0o775)
  assert build_input(pkg)? == first == false
}

test test_x86_build_fingerprint_uses_x86_source_checksum [fs, env, error] { |ctx|
  let pkg = copied_package(ctx, "fingerprint-x86-source")?
  let source = pkg.upstream_sources[0]
  let arm_checksum = {arch: "aarch64", sha256: "arm-source"}
  let x86_checksum = {arch: "x86_64", sha256: "x86-source"}
  let selected = {...pkg, upstream_sources: [{...source, checksums: [arm_checksum, x86_checksum]}]}
  let baseline = fingerprint.package_build_input(p".", selected, types.target_x86_64())?
  let arm_changed = {
    ...selected,
    upstream_sources: [{...source, checksums: [{...arm_checksum, sha256: "changed-arm"}, x86_checksum]}],
  }
  let x86_changed = {
    ...selected,
    upstream_sources: [{...source, checksums: [arm_checksum, {...x86_checksum, sha256: "changed-x86"}]}],
  }

  assert fingerprint.package_build_input(p".", arm_changed, types.target_x86_64())? == baseline
  assert fingerprint.package_build_input(p".", x86_changed, types.target_x86_64())? == baseline == false
}

test test_package_build_fingerprint_changes_for_pkgbuild [fs, env, error] { |ctx|
  let pkg = copied_package(ctx, "fingerprint-pkgbuild")?
  let first = build_input(pkg)?
  let pkgbuild = fp"{pkg.dir}/PKGBUILD.xsh"
  pkgbuild.write(pkgbuild.read_text()?.replace("1.0.0", with: "1.0.1"))
  assert build_input(pkg)? == first == false
}

test test_package_build_fingerprint_changes_for_helper_module [fs, env, error] { |ctx|
  let pkg = copied_package(ctx, "fingerprint-helper")?
  let first = build_input(pkg)?
  fp"{pkg.dir}/helper.xsh".write("changed helper\n")
  assert build_input(pkg)? == first == false
}

test test_package_build_fingerprint_changes_for_files_tree [fs, env, error] { |ctx|
  let pkg = copied_package(ctx, "fingerprint-files")?
  let first = build_input(pkg)?
  fp"{pkg.dir}/files/input.txt".write("changed input\n")
  assert build_input(pkg)? == first == false
}

test test_package_build_fingerprint_changes_for_service [fs, env, error] { |ctx|
  let pkg = copied_package(ctx, "fingerprint-service")?
  let first = build_input(pkg)?
  fp"{pkg.dir}/service.xsh".write("changed service\n")
  assert build_input(pkg)? == first == false
}

test test_proof_fingerprint_is_independent_from_build_input [fs, env, error] { |ctx|
  let pkg = copied_package(ctx, "fingerprint-proof")?
  let build_before = build_input(pkg)?
  let proof_before = fingerprint.package_proof_input(p".", pkg)?
  fp"{pkg.dir}/proof.xsh".write("changed proof\n")
  assert build_input(pkg)? == build_before
  assert fingerprint.package_proof_input(p".", pkg)? == proof_before == false
}

test test_pm_tree_fingerprint_changes_for_implementation [fs, error] { |ctx|
  let root = copied_executor(ctx)?
  let first = fingerprint.pm_tree(root)?
  fp"{root}/pm/build.xsh".write("changed implementation\n")
  assert fingerprint.pm_tree(root)? == first == false
}

test test_core_tree_fingerprint_changes_for_applet [fs, error] { |ctx|
  let root = copied_executor(ctx)?
  let first = fingerprint.core_tree(fp"{root}/core")?
  fp"{root}/core/applet.xsh".write("changed applet\n")
  assert fingerprint.core_tree(fp"{root}/core")? == first == false
}

test test_package_fingerprint_ignores_absolute_checkout_path [fs, env, error] { |ctx|
  let first = copied_package(ctx, "fingerprint-checkout-a")?
  let second = copied_package(ctx, "fingerprint-checkout-b")?
  test.eq(build_input(first)?, build_input(second)?)
}

# The digest records symlinks by target text and never follows them, so a link
# out of the recipe directory is refused instead of hiding outside content.
test test_package_fingerprint_refuses_symlinks_leaving_the_recipe [fs, env, error] { |ctx|
  let pkg = copied_package(ctx, "fingerprint-symlinks")?
  let first = build_input(pkg)?
  fp"{pkg.dir}/files/inside.txt".symlink(to: p"input.txt")
  assert build_input(pkg)? == first == false

  for target in [../../pm, /etc, p"files/../../outside.xsh"] {
    let link = fp"{pkg.dir}/escape"
    link.remove(missing_ok: true)
    link.symlink(to: target)

    match build_input(pkg) {
      Ok(_) => test.fail(f"recipe symlink to {target} unexpectedly fingerprinted")
      Err(problem) => assert "recipe symlink escape -> " in problem.message and "leaves the recipe directory" in problem.message
    }
  }
}

pure empty_remote_snapshot() -> types.RemoteSnapshot {
  {target: types.Aarch64LinuxMusl, index_sha256: "remote-index", packages: []}
}

proc copied_plan_repository(ctx: TestContext, name: Str) [fs, env, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name:)?
  let _ = fs.copy_tree(fixture("graph-catalog/packages"), fp"{root}/packages", parents: true, overwrite: true)?
  fp"{root}/pm".mkdir()
  p"pm/proof.xsh".copy(to: fp"{root}/pm/proof.xsh", overwrite: true)
  root
}

proc plan_catalog(ctx: TestContext, name: Str) -> Result[types.PackageCatalog] {
  catalog.load(copied_plan_repository(ctx, name)?)?
}

proc resolve_plan(
  value: types.PackageCatalog,
  roots: List[Str],
  snapshot: types.RemoteSnapshot,
) -> Result[types.BuildPlan] {
  plan.resolve(value, snapshot, policy.aarch64_docker(), roots, false)?
}

pure retrieval_for(name: Str, ver: Str, rel: Str) -> types.RemoteRetrieval {
  {
    arch: "aarch64",
    tarball: f"packages/aarch64/{name}/{name}-{ver}-{rel}.tar.gz",
    tarball_sha256: f"payload-{name}-{ver}-{rel}",
    metadata: f"metadata/aarch64/{name}/{name}-{ver}-{rel}.json",
    metadata_sha256: f"metadata-{name}-{ver}-{rel}",
  }
}

pure plan_test_sha256(value: Str) -> Str {
  bytes.from_text(value).sha256().hex()
}

pure legacy_retrieval_for(name: Str, ver: Str, rel: Str) -> types.RemoteRetrieval {
  {
    arch: "aarch64",
    tarball: f"packages/aarch64/{name}/{name}-{ver}-{rel}.tar.gz",
    tarball_sha256: plan_test_sha256(f"legacy payload {name}-{ver}-{rel}"),
    metadata: f"metadata/aarch64/{name}/{name}-{ver}-{rel}.json",
    metadata_sha256: plan_test_sha256(f"legacy metadata {name}-{ver}-{rel}"),
  }
}

proc exact_remote_snapshot(value: types.BuildPlan) [error] -> Result[types.RemoteSnapshot] {
  var packages: List[types.RemotePlanArtifact] = [
    {
      name: node.name,
      ver: node.ver,
      rel: node.rel,
      retrieval: retrieval_for(node.name, node.ver, node.rel),
      artifact_key: node.artifact_key,
      recipe_sha256: node.recipe_sha256,
      executor_sha256: plan_test_sha256("remote executor"),
      proof_key: node.proof_key,
      proof_sha256: node.proof_sha256,
    }
    for node in value.nodes
  ]
  {target: value.target, index_sha256: "remote-index", packages}
}

proc node_named(value: types.BuildPlan, name: Str) [error] -> Result[types.PlanNode] {
  for node in value.nodes {
    return node when node.name == name
  }

  Err(types.PmError.PackageContract(f"missing plan node {name}"))
}

pure snapshot_replace(
  value: types.RemoteSnapshot,
  name: Str,
  replacement: types.RemotePlanArtifact,
) -> types.RemoteSnapshot {
  {...value, packages: [if item.name == name { replacement } else { item } for item in value.packages]}
}

proc expect_plan_rejection(ctx: TestContext, value: types.BuildPlan, expected: Str) {
  let path_value = fp"{test.temp_dir(ctx, name: "invalid-plan")?}/plan.json"
  plan_json.write_plan(path_value, value)
  let raw = json.read(path_value)?.require(plan_json.BuildPlanDto)?
  let nodes = raw.nodes
  let duplicate = {...raw, nodes: nodes.push(nodes[0])}
  path_value.write(json.encode(duplicate)?)

  match plan_json.read(path_value) {
    Ok(_) => test.fail(f"{expected}: malformed plan unexpectedly loaded")
    Err(problem) => assert expected in problem.message
  }
}

test test_build_plan_is_deterministic_and_has_dependency_first_order [fs, env, error] { |ctx|
  let value = plan_catalog(ctx, "plan-deterministic")?
  let first = resolve_plan(value, ["app"], empty_remote_snapshot())?
  let second = resolve_plan(value, ["app"], empty_remote_snapshot())?
  assert first == second
  assert first.roots == ["app"]
  assert [node.name for node in first.nodes] == ["host-tool", "runtime-lib", "target-sdk", "app"]
  assert [node.level for node in first.nodes] == [0, 0, 0, 1]
  assert types.plan_action_text(node_named(first, "app")?.action) == "build"
  assert types.plan_action_reason(node_named(first, "app")?.action) == "new package"
}

test test_build_plan_all_roots_are_canonical [fs, env, error] { |ctx|
  let value = plan_catalog(ctx, "plan-all")?
  let first = plan.resolve(value, empty_remote_snapshot(), policy.aarch64_docker(), ["target-sdk", "app"], true)?
  let second = plan.resolve(value, empty_remote_snapshot(), policy.aarch64_docker(), ["app"], true)?
  assert first == second
  assert first.roots == ["app", "host-tool", "runtime-lib", "target-sdk"]
}

test test_build_plan_is_checkout_independent [fs, env, error] { |ctx|
  let first = resolve_plan(plan_catalog(ctx, "plan-checkout-a")?, ["app"], empty_remote_snapshot())?
  let second = resolve_plan(plan_catalog(ctx, "plan-checkout-b")?, ["app"], empty_remote_snapshot())?
  assert first == second
}

test test_build_plan_reuses_exact_remote_and_carries_retrieval [fs, env, error] { |ctx|
  let value = plan_catalog(ctx, "plan-remote-exact")?
  let initial = resolve_plan(value, ["app"], empty_remote_snapshot())?
  let reused = resolve_plan(value, ["app"], exact_remote_snapshot(initial)?)?
  let app = node_named(reused, "app")?
  assert types.plan_action_text(app.action) == "reuse-remote"
  assert types.plan_action_reason(app.action) == "exact remote artifact"
  assert app.remote != null
  assert app.artifact_key == node_named(initial, "app")?.artifact_key
}

test test_build_plan_marks_only_retrieval_derived_remote_keys_as_legacy [fs, env, error] { |ctx|
  let value = plan_catalog(ctx, "plan-legacy-remote")?
  let initial = resolve_plan(value, ["app"], empty_remote_snapshot())?
  let app = node_named(initial, "app")?
  let legacy_packages: List[types.RemotePlanArtifact] = [
    {
      name: node.name,
      ver: node.ver,
      rel: node.rel,
      retrieval: legacy_retrieval_for(node.name, node.ver, node.rel),
      artifact_key: "",
      recipe_sha256: "",
      executor_sha256: "",
      proof_key: "",
      proof_sha256: "",
    }
    for node in initial.nodes
  ]
  let legacy = {
    target: types.Aarch64LinuxMusl,
    index_sha256: "legacy-remote-index",
    packages: legacy_packages,
  }
  let resolved = resolve_plan(value, ["app"], legacy)?
  assert plan.node_uses_legacy_remote_identity(resolved, node_named(resolved, "app")?)?
  assert plan.node_uses_legacy_remote_identity(initial, app)? == false
}

test test_build_plan_reports_tuple_reasons_and_rejects_behind_remote [fs, env, error] { |ctx|
  let value = plan_catalog(ctx, "plan-reasons")?
  let initial = resolve_plan(value, ["runtime-lib"], empty_remote_snapshot())?
  let snapshot = exact_remote_snapshot(initial)?
  let remote = snapshot.packages[0]
  let older = snapshot_replace(snapshot, "runtime-lib", {...remote, ver: "0"})
  let lower_release = snapshot_replace(snapshot, "runtime-lib", {...remote, rel: "0"})
  let newer = snapshot_replace(snapshot, "runtime-lib", {...remote, ver: "2"})
  let version_build = resolve_plan(value, ["runtime-lib"], older)?
  let release_build = resolve_plan(value, ["runtime-lib"], lower_release)?
  assert types.plan_action_reason(node_named(version_build, "runtime-lib")?.action) == "local version differs from remote 0-1"
  assert types.plan_action_reason(node_named(release_build, "runtime-lib")?.action) == "local release is above remote 1-0"

  match resolve_plan(value, ["runtime-lib"], newer) {
    Ok(_) => test.fail("behind remote tuple unexpectedly planned")
    Err(problem) => assert "behind remote 2-1" in problem.message
  }
}

proc with_release(value: types.PackageCatalog, name: Str, rel: Str) -> Result[types.PackageCatalog] {
  catalog.from_packages(value.root, [if pkg.name == name { {...pkg, rel} } else { pkg } for pkg in value.packages])?
}

proc changed_key_names(before: types.BuildPlan, after: types.BuildPlan) -> Result[List[Str]] {
  var changed = [
    node.name
    for node in before.nodes
    if node_named(after, node.name)?.artifact_key != node.artifact_key
  ]
  changed |> sort
}

# Every direct dependency, runtime ones included, is installed into a build
# root, so a release bump changes exactly the package and its dependents.
test test_release_bump_changes_exactly_the_package_and_its_dependents [fs, env, error] { |ctx|
  let value = plan_catalog(ctx, "plan-propagation")?
  let initial = resolve_plan(value, ["app"], empty_remote_snapshot())?

  for name in ["host-tool", "target-sdk", "runtime-lib"] {
    let bumped = resolve_plan(with_release(value, name, "2")?, ["app"], empty_remote_snapshot())?
    assert changed_key_names(initial, bumped)? == ([name, "app"] |> sort)
  }

  let app_bumped = resolve_plan(with_release(value, "app", "2")?, ["app"], empty_remote_snapshot())?
  assert changed_key_names(initial, app_bumped)? == ["app"]
}

test test_build_epoch_changes_every_artifact_key_and_nothing_else [fs, env, error] { |ctx|
  let value = plan_catalog(ctx, "plan-build-epoch")?
  let current = resolve_plan(value, ["app"], empty_remote_snapshot())?
  let next_policy = {...policy.aarch64_docker(), build_epoch: policy.BUILD_EPOCH + 1}
  let next = plan.resolve(value, empty_remote_snapshot(), next_policy, ["app"], false)?
  assert current.build_epoch == policy.BUILD_EPOCH
  assert next.build_epoch == policy.BUILD_EPOCH + 1
  assert changed_key_names(current, next)? == ([node.name for node in current.nodes] |> sort)
  assert [node.recipe_sha256 for node in next.nodes] == [node.recipe_sha256 for node in current.nodes]
}

test test_build_plan_keeps_same_package_dependency_edges_by_kind [fs, env, error] { |ctx|
  let original = plan_catalog(ctx, "plan-edge-kinds")?
  var packages: List[types.Package] = []

  for pkg in original.packages {
    packages += [if pkg.name == "app" {
        {...pkg, mkdeps_host: pkg.mkdeps_host.push("runtime-lib")}
      } else {
        pkg
      }]
  }

  let value = catalog.from_packages(original.root, packages)?
  let resolved = resolve_plan(value, ["app"], empty_remote_snapshot())?
  let app = node_named(resolved, "app")?
  let runtime_edges = [dependency for dependency in app.dependencies if dependency.name == "runtime-lib"]
  assert [types.dependency_kind_text(dependency.kind) for dependency in runtime_edges] == ["build-host", "runtime"]
  assert runtime_edges[0].artifact_key == runtime_edges[1].artifact_key

  let repeated = {...app, dependencies: app.dependencies.push(app.dependencies[0])}
  let malformed = {...resolved, nodes: [if node.name == "app" { repeated } else { node } for node in resolved.nodes]}

  match plan.fingerprint(malformed) {
    Ok(_) => test.fail("same-kind duplicate dependency unexpectedly validated")
    Err(problem) => {
      let problem_message = problem.message
      assert f"repeats {types.dependency_kind_text(app.dependencies[0].kind)} dependency {app.dependencies[0].name}" in problem_message
    }
  }
}

# A dependent whose dependency is rebuilt is rebuilt locally without a release
# bump; publishing it under the remote's tuple is a `repo publish` conflict.
test test_build_plan_rebuilds_dependents_of_rebuilt_dependencies [fs, env, error] { |ctx|
  let value = plan_catalog(ctx, "plan-dependency-rebuild")?
  let snapshot = exact_remote_snapshot(resolve_plan(value, ["app"], empty_remote_snapshot())?)?
  let rebuilt = resolve_plan(with_release(value, "runtime-lib", "2")?, ["app"], snapshot)?
  assert types.plan_action_reason(node_named(rebuilt, "runtime-lib")?.action) == "local release is above remote 1-1"
  assert types.plan_action_text(node_named(rebuilt, "app")?.action) == "build"
  assert types.plan_action_reason(node_named(rebuilt, "app")?.action) == "dependencies rebuilt (runtime-lib)"
  assert types.plan_action_text(node_named(rebuilt, "host-tool")?.action) == "reuse-remote"

  # Remote executor provenance never decides reuse.
  let other_executor = {
    ...snapshot,
    packages: [{...artifact, executor_sha256: plan_test_sha256("other executor")} for artifact in snapshot.packages],
  }
  let reused = resolve_plan(value, ["app"], other_executor)?
  assert [types.plan_action_text(node.action) for node in reused.nodes] == [
    "reuse-remote",
    "reuse-remote",
    "reuse-remote",
    "reuse-remote",
  ]
}

test test_build_plan_json_round_trip_and_detects_corruption [fs, env, error] { |ctx|
  let value = resolve_plan(plan_catalog(ctx, "plan-json")?, ["app"], empty_remote_snapshot())?
  let path_value = fp"{test.temp_dir(ctx, name: "plan-json-out")?}/basic-aarch64.json"
  let repeat_path = fp"{test.temp_dir(ctx, name: "plan-json-repeat")?}/basic-aarch64.json"
  plan_json.write_plan(path_value, value)
  plan_json.write_plan(repeat_path, value)
  assert plan_json.read(path_value)? == value

  let original = path_value.read_text()?
  assert repeat_path.read_text()? == original
  assert original == fixture("plans/basic-aarch64.json").read_text()?
  path_value.write(original.replace(plan.format, with: "unknown-build-plan"))

  match plan_json.read(path_value) {
    Ok(_) => test.fail("unknown plan format unexpectedly loaded")
    Err(problem) => assert "unsupported build plan format unknown-build-plan" in problem.message
  }

  path_value.write(original.replace(value.repository_digest, with: "corrupt-repository-digest"))

  match plan_json.read(path_value) {
    Ok(_) => test.fail("corrupt plan digest unexpectedly loaded")
    Err(problem) => assert "digest does not match" in problem.message
  }
}

test test_build_plan_json_rejects_duplicate_nodes [fs, env, error] { |ctx|
  expect_plan_rejection(
    ctx,
    resolve_plan(plan_catalog(ctx, "plan-duplicate")?, ["app"], empty_remote_snapshot())?,
    "duplicate node host-tool",
  )
}

test test_build_plan_json_rejects_dependency_key_mismatch [fs, env, error] { |ctx|
  let value = resolve_plan(plan_catalog(ctx, "plan-dependency-key")?, ["app"], empty_remote_snapshot())?
  let path_value = fp"{test.temp_dir(ctx, name: "plan-dependency-key")?}/plan.json"
  plan_json.write_plan(path_value, value)
  let raw = json.read(path_value)?.require(plan_json.BuildPlanDto)?
  let original_nodes = raw.nodes
  var nodes = []

  for node in original_nodes {
    let name = node.name

    if name == "app" {
      let dependencies = node.dependencies
      let dependency = dependencies[0]
      nodes += [{...node, dependencies: [{...dependency, artifact_key: "tampered"}]}]
    } else {
      nodes += [node]
    }
  }

  path_value.write(json.encode({...raw, nodes})?)

  match plan_json.read(path_value) {
    Ok(_) => test.fail("dependency key mismatch unexpectedly loaded")
    Err(problem) => assert "dependency host-tool artifact key does not match its referenced node" in problem.message
  }
}

test test_build_plan_normalizes_target_aliases_and_rejects_reserved_target [fs, env, error] { |ctx|
  assert types.parse_target("arm64")? == .Aarch64LinuxMusl
  assert types.parse_target("amd64")? == .X86_64LinuxMusl
  let value = plan_catalog(ctx, "plan-target")?
  let unsupported = {...policy.aarch64_docker(), target: types.TargetReserved}

  match plan.resolve(value, empty_remote_snapshot(), unsupported, ["app"], false) {
    Ok(_) => test.fail("unsupported target unexpectedly planned")
    Err(problem) => assert "unsupported target" in problem.message
  }
}

proc write_plan_metapackage(root: Path, name: Str, dependencies: Str) {
  let dir = fp"{root}/packages/{name}"
  dir.mkdir()
  let documented = dependencies.replace("export let ", with: "## Fixture export.\nexport let ")
  fp"{dir}/PKGBUILD.xsh".write(
    f"""##! Runtime-only dependency fixture recipe.
## Fixture export.
export let name = "{name}"
## Fixture export.
export let package_kind = "meta"
## Fixture export.
export let ver = "1"
## Fixture export.
export let rel = "1"
{documented}
## Fixture export.
export let mkdeps_host = []
## Fixture export.
export let upstream_sources = []
## Fixture export.
export let filetree = []
""",
  )
}

# `service` runtime-only depends on `app`, whose build inputs are host-tool,
# runtime-lib, and target-sdk; `consumer` builds against `service`.
proc runtime_only_plan_catalog(ctx: TestContext, name: Str) -> Result[types.PackageCatalog] {
  let root = copied_plan_repository(ctx, name)?
  write_plan_metapackage(root, "service", "export let deps = []\nexport let runtime_only_deps = [\"app\"]")
  write_plan_metapackage(root, "consumer", "export let deps = [\"service\"]")
  catalog.load(root)?
}

test test_runtime_only_dependency_is_planned_but_neither_ordered_nor_keyed [fs, env, error] { |ctx|
  let value = runtime_only_plan_catalog(ctx, "plan-runtime-only")?
  let initial = resolve_plan(value, ["consumer"], empty_remote_snapshot())?
  assert [node.name for node in initial.nodes] == [
    "host-tool",
    "runtime-lib",
    "service",
    "target-sdk",
    "app",
    "consumer",
  ]
  let service = node_named(initial, "service")?
  assert service.level == 0
  test.eq(
    service.dependencies,
    [{name: "app", kind: types.RuntimeOnly, artifact_key: node_named(initial, "app")?.artifact_key}],
  )

  let path_value = fp"{test.temp_dir(ctx, name: "plan-runtime-only-json")?}/plan.json"
  plan_json.write_plan(path_value, initial)
  assert plan_json.read(path_value)? == initial

  # Rebuilding a runtime-only dependency rebuilds none of its dependents.
  let app_bumped = resolve_plan(with_release(value, "app", "2")?, ["consumer"], empty_remote_snapshot())?
  assert changed_key_names(initial, app_bumped)? == ["app"]
  assert node_named(app_bumped, "service")?.dependencies[0].artifact_key == node_named(app_bumped, "app")?.artifact_key

  # A build dependency still cascades through its build dependents only.
  let lib_bumped = resolve_plan(with_release(value, "runtime-lib", "2")?, ["consumer"], empty_remote_snapshot())?
  assert changed_key_names(initial, lib_bumped)? == ["app", "runtime-lib"]
  let service_bumped = resolve_plan(with_release(value, "service", "2")?, ["consumer"], empty_remote_snapshot())?
  assert changed_key_names(initial, service_bumped)? == ["consumer", "service"]

  # An exact remote dependent stays reusable when its runtime-only dependency is rebuilt.
  let rebuilt = resolve_plan(with_release(value, "app", "2")?, ["consumer"], exact_remote_snapshot(initial)?)?
  assert types.plan_action_text(node_named(rebuilt, "app")?.action) == "build"
  assert types.plan_action_text(node_named(rebuilt, "service")?.action) == "reuse-remote"
  assert types.plan_action_text(node_named(rebuilt, "consumer")?.action) == "reuse-remote"
}

test test_runtime_only_dependency_may_close_a_cycle [fs, env, error] { |ctx|
  let root = copied_plan_repository(ctx, "plan-runtime-only-cycle")?
  write_plan_metapackage(root, "service", "export let deps = []\nexport let runtime_only_deps = [\"runner\"]")
  write_plan_metapackage(root, "runner", "export let deps = [\"service\"]")
  let resolved = resolve_plan(catalog.load(root)?, ["runner"], empty_remote_snapshot())?
  assert [node.name for node in resolved.nodes] == ["service", "runner"]
  assert [dependency.kind for dependency in node_named(resolved, "service")?.dependencies] == [types.RuntimeOnly]
  plan.validate(resolved)
}

# Versions compare as runs of digits (numerically) and letters (as text), and
# a digit run outranks a letter run, as rpm and apk order them.
test test_version_order_compares_digit_and_letter_runs [error] {
  let older_newer = [
    ["next-3.7", "3.7c"],
    ["3.7", "3.7c"],
    ["3.7b", "3.7c"],
    ["1.2.9", "1.2.10"],
    ["2.1.12-stable", "2.1.13-stable"],
    ["701", "710"],
    ["0.9", "0.10"],
    ["23.1.0-rc2", "23.1.0"],
  ]

  for pair in older_newer {
    assert plan.plan_compare_version_release(pair[0], "1", pair[1], "1") < 0, f"{pair[0]} < {pair[1]}"
    assert plan.plan_compare_version_release(pair[1], "1", pair[0], "1") > 0, f"{pair[1]} > {pair[0]}"
  }

  assert plan.plan_compare_version_release("1.0", "1", "1.0", "1") == 0
  assert plan.plan_compare_version_release("1.0", "2", "1.0", "10") < 0
}
