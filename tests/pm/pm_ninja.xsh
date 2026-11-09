##! Behavior coverage for rewriting generated Ninja command arguments.
use pm.fingerprint
use pm.ninja as pm_ninja
use pm.recipe
use pm.types

const manifest = "build a: CUSTOM_COMMAND b\n  COMMAND = /r/bin/scanner -s x /r/bin/scanner2\n  DESC = Generating /r/bin/scanner\n"

test test_rewrite_replaces_only_the_exact_command_argument [error] {
  let rewritten = pm_ninja.ninja_rewrite_command_arguments(manifest, ["/r/bin/scanner"], "/n/scanner")?
  assert rewritten == "build a: CUSTOM_COMMAND b\n  COMMAND = /n/scanner -s x /r/bin/scanner2\n  DESC = Generating /r/bin/scanner\n"
}

test test_rewrite_refuses_a_path_no_command_uses [error] {
  assert pm_ninja.ninja_rewrite_command_arguments(manifest, ["/missing"], "/n/scanner") is Err(_)
}

test test_helper_changes_invalidate_each_consumer [fs, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "ninja-helper-input")?
  fp"{root}/pm".mkdir(parents: true)?
  let helper = fp"{root}/pm/ninja.xsh"
  helper.write("first\n")?
  let names = ["wayland-dev", "wayland-libs-client", "wayland-libs-server", "wayland-libs-cursor", "wl-clipboard", "libva"]
  let checkout = fs.cwd()?
  let packages = [recipe.load_package(fp"{checkout}/packages/{name}")? for name in names]
  let before = [fingerprint.package_build_input(root, pkg, types.target_x86_64())? for pkg in packages]
  helper.write("second\n")?
  for index in range(0, packages.len()) {
    assert fingerprint.package_build_input(root, packages[index], types.target_x86_64())? != before[index]
  }
}
