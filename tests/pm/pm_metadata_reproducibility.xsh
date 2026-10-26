use pm.local
use pm.recipe

test test_installed_metadata_does_not_depend_on_recipe_checkout_location [fs, env, error] { |ctx|
  let first = test.temp_dir(ctx, name: "metadata-first-checkout")?
  let second = test.temp_dir(ctx, name: "metadata-relocated-checkout")?
  let pkg = recipe.load_package(p"tests/pm/fixtures/execute/packages/execute-dep")?
  let first_root = fp"{first}/root"
  let second_root = fp"{second}/root"
  local.write_package_db(first_root, {...pkg, dir: fp"{first}/packages/execute-dep"}, [], [])
  local.write_package_db(second_root, {...pkg, dir: fp"{second}/packages/execute-dep"}, [], [])
  let relative = "var/lib/xsh-pm/packages/execute-dep/metadata.json"
  assert fp"{first_root}/{relative}".read_bytes()? == fp"{second_root}/{relative}".read_bytes()?
}
