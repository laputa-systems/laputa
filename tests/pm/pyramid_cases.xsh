use pm.catalog
use pm.execute
use pm.local
use pm.plan
use pm.policy
use pm.root
use pm.store
use pm.types

proc pyramid_repository(ctx: TestContext, name: Str) [fs, env, error] -> Result[Path] {
  let repository = test.temp_dir(ctx, name:)?
  let _ = fs.copy_tree(p"tests/pm/fixtures/execute/packages", fp"{repository}/packages", parents: true, overwrite: true)?
  fp"{repository}/pm".mkdir()
  p"pm/proof.xsh".copy(to: fp"{repository}/pm/proof.xsh", overwrite: true)
  repository
}

proc pyramid_plan(repository: Path, roots: List[Str]) [fs, env, error] -> Result[types.BuildPlan] {
  plan.resolve(
    catalog.load_for_target(repository, types.target_x86_64())?,
    {target: types.target_x86_64(), index_sha256: "pyramid-offline-empty", packages: []},
    policy.x86_64_docker(),
    roots,
    false,
  )?
}

test test_pyramid_pm_plan_exact_inventory [fs, env, error] { |ctx|
  let repository = pyramid_repository(ctx, "pyramid-plan")?
  let value = pyramid_plan(repository, ["execute-app"])?
  assert value.roots == ["execute-app"]
  assert [node.name for node in value.nodes] == ["execute-dep", "execute-tool", "execute-app"]
  assert [node.level for node in value.nodes] == [0, 0, 1]
  assert [types.plan_action_text(node.action) for node in value.nodes] == ["build", "build", "build"]
  assert [node.dependencies.len() for node in value.nodes] == [0, 0, 2]
  assert [edge.name for edge in value.nodes[2].dependencies] == ["execute-tool", "execute-dep"]
  assert [types.dependency_kind_text(edge.kind) for edge in value.nodes[2].dependencies] == ["build-host", "runtime"]
}

test test_pyramid_pm_selected_fresh_build_and_reuse [fs, net, process, env, time, error] { |ctx|
  let repository = pyramid_repository(ctx, "pyramid-fresh")?
  let object_store = test.temp_dir(ctx, name: "pyramid-fresh-store")?
  let markers = test.temp_dir(ctx, name: "pyramid-build-records")?
  for name in ["execute-dep", "execute-tool", "execute-app"] {
    let recipe = fp"{repository}/packages/{name}/PKGBUILD.xsh"
    recipe.write(recipe.read_text()?.replace("[fs, error]", with: "[fs, env, error]").replace(
      "  let target =",
      with: f"""  let marker = fp"{markers}/{name}"
  fail "package built twice" when marker.exists()?
  marker.write("built")?
  let target =""",
    ))
  }
  let app_recipe = fp"{repository}/packages/execute-app/PKGBUILD.xsh"
  app_recipe.write(app_recipe.read_text()?.replace(
    r"""kind: "file"}]""",
    with: r"""kind: "file"}, {path: p"usr/share/execute-app-link.txt", kind: "symlink"}]""",
  ).replace(
    r"""  target.write("application v1\n")?""",
    with: r"""  target.write("application v1\n")?
  fp"{dest}/usr/share/execute-app-link.txt".symlink(to: p"execute-app.txt")?""",
  ))
  let dependencies = pyramid_plan(repository, ["execute-dep", "execute-tool"])?
  let prepared = execute.build_plan(dependencies, repository, object_store, "", 1)?
  assert [receipt.package_name for receipt in prepared.artifacts] == ["execute-dep", "execute-tool"]
  let value = pyramid_plan(repository, ["execute-app"])?
  var reused: List[Str] = []
  var fresh: List[Str] = []
  for node in value.nodes {
    if store.artifact_path(object_store, node.artifact_key).exists()? {
      reused += [node.name]
    } else {
      fresh += [node.name]
    }
  }
  assert reused == ["execute-dep", "execute-tool"]
  assert fresh == ["execute-app"]
  let result = execute.build_plan(value, repository, object_store, "", 1)?
  assert [result.artifacts[0], result.artifacts[1]] == prepared.artifacts
  assert [receipt.package_name for receipt in result.artifacts] == ["execute-dep", "execute-tool", "execute-app"]
  for receipt in result.artifacts {
    assert store.lookup(object_store, receipt.key)? == receipt
  }
  let app = result.artifacts[2]
  let metadata = json.read(fp"{app.artifact_dir}/metadata.json")?.require(local.PackageMetadataDto)?
  assert [entry.path for entry in metadata.files] == [
    "usr/share/execute-app-link.txt",
    "usr/share/execute-app.txt",
    "var/lib/xsh-pm/packages/execute-app/etcsums.json",
    "var/lib/xsh-pm/packages/execute-app/manifest.json",
    "var/lib/xsh-pm/packages/execute-app/metadata.json",
  ]
  assert ([entry.name for entry in fs.children(markers)?] |> sort) == ["execute-app", "execute-dep", "execute-tool"]
  let composed = root.preflight(value.target, [result.artifacts[0], app])?
  assert [entry.path for entry in composed.entries] == [
    "usr/share/execute-app-link.txt",
    "usr/share/execute-app.txt",
    "usr/share/execute-dep.txt",
    "var/lib/xsh-pm/packages/execute-app/etcsums.json",
    "var/lib/xsh-pm/packages/execute-app/manifest.json",
    "var/lib/xsh-pm/packages/execute-app/metadata.json",
    "var/lib/xsh-pm/packages/execute-dep/etcsums.json",
    "var/lib/xsh-pm/packages/execute-dep/manifest.json",
    "var/lib/xsh-pm/packages/execute-dep/metadata.json",
  ]
  assert [entry.package_name for entry in composed.entries] == [
    "execute-app", "execute-app", "execute-dep", "execute-app", "execute-app", "execute-app", "execute-dep", "execute-dep", "execute-dep",
  ]
  let output = fp"{test.temp_dir(ctx, name: "pyramid-root")?}/root"
  let receipt = root.compose_artifacts(output, composed, [result.artifacts[0], app])?
  assert fp"{output}/usr/share/execute-app.txt".read_text()? == "application v1\n"
  assert fp"{output}/usr/share/execute-dep.txt".read_text()? == "dependency\n"
  assert fp"{output}/usr/share/execute-tool.txt".exists()? == false
  assert fp"{output}/usr/share/execute-app-link.txt".readlink()?.display() == "execute-app.txt"
  root.verify(output, receipt)
  let repeated = execute.build_plan(value, repository, object_store, "", 1)?
  assert repeated == result
}
