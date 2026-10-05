##! Artifact-key and runtime-closure behavior of the checked-in recipes.
use pm.catalog
use pm.generation
use pm.plan
use pm.policy
use pm.types

# Packages whose keys must not follow the XSH seed: XSH scripts, service
# modules run by xinit, and their dependents.
const seed_independent = ["dropbear", "laputa-fs", "laputa-net", "laputa-pm", "tailscale", "xinit"]

# The `xsh` recipe hashes the local seed under `.out/`, which only `make seed`
# produces. Share the checked-in recipes and repository inputs with a
# disposable root that holds a fixture seed for each target.
proc repository_with_seeds(ctx: TestContext, name: Str) -> Result[Path] {
  let checkout = fs.cwd()?
  let root = test.temp_dir(ctx, name:)?

  for entry in ["packages", "pm", "pm.xsh", "xinit"] {
    fp"{root}/{entry}".symlink(to: fp"{checkout}/{entry}")
  }

  for arch in ["aarch64", "x86_64"] {
    let seed = fp"{root}/.out/seed/{arch}"
    seed.mkdir()

    for product in ["xsh", "xshi", "xsht", "core.tar.xz", "manifest.json"] {
      fp"{seed}/{product}".write(f"fixture {arch} {product}\n")
    }
  }

  root
}

proc rebuild_seed(root: Path, arch: Str) [fs, error] {
  fp"{root}/.out/seed/{arch}/xsh".write(f"rebuilt {arch} xsh\n")
}

proc plan_for(
  value: types.PackageCatalog,
  target: types.Target,
  roots: List[Str],
) -> Result[types.BuildPlan] {
  let policy_value = if target == types.target_aarch64() { policy.aarch64_docker() } else { policy.x86_64_docker() }
  plan.resolve(value, {target, index_sha256: "repository-keys-empty-remote", packages: []}, policy_value, roots, false)?
}

proc plan_repository(root: Path, target: types.Target) -> Result[types.BuildPlan] {
  plan_for(catalog.load_for_target(root, target)?, target, ["xsh"].extend(seed_independent))?
}

proc changed_key_names(before: types.BuildPlan, after: types.BuildPlan) -> Result[List[Str]] {
  var keys = {node.name: node.artifact_key for node in after.nodes}
  var changed = [node.name for node in before.nodes if keys.get(node.name)? != node.artifact_key]
  changed |> sort
}

proc with_release(value: types.PackageCatalog, name: Str, rel: Str) -> Result[types.PackageCatalog] {
  catalog.from_packages(value.root, [if pkg.name == name { {...pkg, rel} } else { pkg } for pkg in value.packages])?
}

pure generation_names(value: types.GenerationPlan) -> List[Str] {
  [artifact.package_name for artifact in value.artifacts]
}

test test_seed_rebuild_changes_only_the_xsh_key [fs, env, error] { |ctx|
  let root = repository_with_seeds(ctx, "repository-keys-seed")?
  let before = plan_repository(root, types.target_aarch64())?

  for name in seed_independent {
    assert name in [node.name for node in before.nodes]
  }

  rebuild_seed(root, "aarch64")
  assert changed_key_names(before, plan_repository(root, types.target_aarch64())?)? == ["xsh"]
}

test test_seed_rebuild_changes_only_its_own_target_key [fs, env, error] { |ctx|
  let root = repository_with_seeds(ctx, "repository-keys-arch")?
  let arm_before = plan_repository(root, types.target_aarch64())?
  let x86_before = plan_repository(root, types.target_x86_64())?

  rebuild_seed(root, "x86_64")
  test.eq(changed_key_names(arm_before, plan_repository(root, types.target_aarch64())?)?, [])
  assert changed_key_names(x86_before, plan_repository(root, types.target_x86_64())?)? == ["xsh"]
}

test test_build_dependency_cascades_and_runtime_only_dependency_does_not [fs, env, error] { |ctx|
  let root = repository_with_seeds(ctx, "repository-keys-cascade")?
  let value = catalog.load_for_target(root, types.target_aarch64())?
  let roots = ["dropbear", "laputa-net", "tailscale"]
  let before = plan_for(value, types.target_aarch64(), roots)?

  # dropbear links zlib, so a zlib rebuild rebuilds it.
  let zlib = plan_for(with_release(value, "zlib", "999")?, types.target_aarch64(), roots)?
  assert "zlib" in changed_key_names(before, zlib)?
  assert "dropbear" in changed_key_names(before, zlib)?

  # Service modules only run under xinit; an xinit rebuild rebuilds xinit alone.
  let xinit = plan_for(with_release(value, "xinit", "999")?, types.target_aarch64(), roots)?
  assert changed_key_names(before, xinit)? == ["xinit"]
}

test test_runtime_roots_compose_runtime_only_dependencies [fs, env, error] { |ctx|
  let root = repository_with_seeds(ctx, "repository-keys-generation")?
  let value = plan_for(
    catalog.load_for_target(root, types.target_aarch64())?,
    types.target_aarch64(),
    ["foot-minimal", "laputa-net", "tailscale"],
  )?
  let overlay = generation.overlay_digest(test.temp_dir(ctx, name: "repository-keys-overlay")?)?

  let tailscale = generation_names(generation.plan(value, ["tailscale"], overlay)?)
  assert tailscale == ["iptables", "musl", "tailscale", "xinit", "xsh"]

  let network = generation_names(generation.plan(value, ["laputa-net"], overlay)?)
  for name in ["wpa_supplicant", "xinit", "xsh"] {
    assert name in network
  }

  assert "font-ttf-hack" in generation_names(generation.plan(value, ["foot-minimal"], overlay)?)
}
