##! Maintainer reports reject stale and corrupt artifacts and ambiguous upstream versions.
use pm.catalog
use pm.maintainer
use pm.plan
use pm.plan_json
use pm.policy
use pm.recipe
use pm.store
use pm.types

proc maintainer_repository(ctx: TestContext) -> Result[Path] {
  let repository = test.temp_dir(ctx, name: "maintainer-repository")?
  let _ = fs.copy_tree(p"tests/pm/fixtures/graph-catalog/packages", fp"{repository}/packages", parents: true)?
  let source = fp"{repository}/packages/runtime-lib/PKGBUILD.xsh"
  source.write(source.read_text()?.replace("\"meta\"", with: "\"payload\"").replace("export let filetree = []", with: "export let filetree = [{path: p\"usr/old\", kind: \"file\"}]") + "\n## Restrict the fixture to its saved plan target.\nexport const architectures = [\"aarch64\"]\n## Create the fixture payload destination.\nexport proc build(dest: Path) [fs, error] { dest.mkdir() }\n")
  p"tests/pm/fixtures/recipe-valid-payload/proof.xsh".copy(to: fp"{repository}/packages/runtime-lib/proof.xsh")
  fp"{repository}/pm".mkdir()
  p"pm/proof.xsh".copy(to: fp"{repository}/pm/proof.xsh")
  repository
}

proc maintainer_plan(repository: Path) -> Result[types.BuildPlan] {
  plan.resolve(catalog.load_for_target(repository, types.target_aarch64())?, {target: types.target_aarch64(), index_sha256: "empty", packages: []}, policy.aarch64_docker(), ["runtime-lib"], false)?
}

proc maintainer_artifact(ctx: TestContext, value: types.BuildPlan, metadata_name: Str, inventory: Str) -> Result[Path] {
  let stage = test.temp_dir(ctx, name: f"maintainer-stage-{metadata_name}-{inventory}")?
  let contents = fp"{stage}/contents"
  fp"{contents}/usr".mkdir()
  fp"{contents}/usr/new".write("new output\n")
  if inventory == "extra" { fp"{contents}/usr/extra".write("extra\n") }
  let payload = fp"{stage}/payload.tar.gz"
  archive.tar_create(payload, contents, [p"."], compression: "gz")
  let metadata = fp"{stage}/metadata.json"
  let node = value.nodes[0]
  json.write(metadata, {
    name: metadata_name, ver: node.ver, rel: node.rel, package_kind: "payload",
    files: [{path: if inventory == "missing" { "usr/missing" } else { "usr/new" }, kind: "file", mode: 0o644, sha256: bytes.from_text("new output\n").sha256().hex(), target: ""}],
  })
  let proof = fp"{stage}/proof.json"
  proof.write("verified proof\n")
  let store_root = test.temp_dir(ctx, name: f"maintainer-store-{metadata_name}-{inventory}")?
  let _ = store.commit(value.target, store_root, node, {payload, payload_sha256: hash.sha256(payload)?.hex(), metadata, proof, executor_sha256: bytes.from_text("executor").sha256().hex()})?
  store_root
}

test test_filetree_diff_uses_verified_inventory_and_preserves_recipe [fs, process, env, error] { |ctx|
  let repository = maintainer_repository(ctx)?
  let value = maintainer_plan(repository)?
  let store_root = maintainer_artifact(ctx, value, "runtime-lib", "valid")?
  let pkg = recipe.load_package_for_target(fp"{repository}/packages/runtime-lib", value.target)?
  let source = fp"{pkg.dir}/PKGBUILD.xsh"
  let before = source.read_text()?
  let report = maintainer.maintainer_filetree_diff(pkg, repository, value, store_root)?
  assert "- usr/old file" in report
  assert "+ usr/new file" in report
  assert "export const filetree_aarch64 = [" in report
  assert "{path: p\"usr/new\", kind: \"file\"}" in report
  let saved_plan = test.temp_path(ctx, name: "filetree-plan.json")
  plan_json.write_plan(saved_plan, value)
  let xsh = fp"{e"XSH_HOST" ?? "xsh"}"
  let modules = path.absolute(p".")?
  let command_report = run.text XSH_MODULE_PATH=$modules XSH_PM_REPO="" $xsh pm.xsh -- repo update-filetree runtime-lib --plan $saved_plan --store $store_root --repo $repository
  assert command_report.trim() == report
  assert source.read_text()? == before
  source.write(before + "\n")
  let changed = recipe.load_package_for_target(pkg.dir, value.target)?
  assert maintainer.maintainer_filetree_diff(changed, repository, value, store_root) is Err(_)
}

test test_filetree_diff_rejects_wrong_package_extra_missing_and_corruption [fs, env, error] { |ctx|
  let repository = maintainer_repository(ctx)?
  let value = maintainer_plan(repository)?
  let pkg = recipe.load_package_for_target(fp"{repository}/packages/runtime-lib", value.target)?
  for {name, inventory} in [{name: "wrong-package", inventory: "valid"}, {name: "runtime-lib", inventory: "extra"}, {name: "runtime-lib", inventory: "missing"}] {
    let store_root = maintainer_artifact(ctx, value, name, inventory)?
    assert maintainer.maintainer_filetree_diff(pkg, repository, value, store_root) is Err(_)
  }
  let store_root = maintainer_artifact(ctx, value, "runtime-lib", "valid")?
  let receipt = store.lookup(store_root, value.nodes[0].artifact_key)?
  fp"{receipt.artifact_dir}/payload.tar.gz".write("corrupt")
  assert maintainer.maintainer_filetree_diff(pkg, repository, value, store_root) is Err(_)
}

test test_outdated_reports_numeric_updates_with_source_and_rejects_ambiguous_tags [fs, env, error] { |_|
  let pkg = recipe.load_package(p"tests/pm/fixtures/graph-catalog/packages/runtime-lib")?
  let source = "https://api.github.com/repos/owner/project/releases/latest"
  for version in ["v1.10", "2.0"] {
    let report = maintainer.maintainer_release_report(pkg, source, json.encode({tag_name: version, draft: false, prerelease: false})?)?
    assert "update available" in report
    assert source in report
  }
  assert "current" in maintainer.maintainer_release_report(pkg, source, json.encode({tag_name: "1", draft: false, prerelease: false})?)?
  for version in ["v2.0-rc1", "release-2", "", "2..0", "999999999999999999999999999999999999"] {
    assert maintainer.maintainer_release_report(pkg, source, json.encode({tag_name: version, draft: false, prerelease: false})?) is Err(_)
  }
  assert maintainer.maintainer_release_report(pkg, source, json.encode({tag_name: "2", draft: false, prerelease: true})?) is Err(_)
  assert maintainer.maintainer_release_report(pkg, source, "{}") is Err(_)
  assert maintainer.maintainer_release_report(pkg, source, "broken JSON") is Err(_)
}
