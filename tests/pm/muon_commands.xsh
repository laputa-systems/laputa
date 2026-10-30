use pm.fingerprint
use pm.muon
use pm.recipe
use pm.types

test test_rewrites_literal_and_structured_arguments_together {
  let old = "scanner old"
  let replacement = "native scanner $x"
  let text = f"""build out: CUSTOM_COMMAND
 COMMAND = runner -- {old} invoke
 ARGV_COMMAND = x72756e6e6572 x2d2d {muon.muon_encoded_argument(old)} x696e766f6b65
"""
  let expected = f"""build out: CUSTOM_COMMAND
 COMMAND = runner -- {replacement} invoke
 ARGV_COMMAND = x72756e6e6572 x2d2d {muon.muon_encoded_argument(replacement)} x696e766f6b65
"""
  test.eq(muon.muon_rewrite_ninja_argument(text, old, replacement)?, expected)
}

test test_rejects_command_without_matching_structured_argument {
  let text = " COMMAND = runner -- old\n ARGV_COMMAND = x72756e6e6572\n"
  match muon.muon_rewrite_ninja_argument(text, "old", "new") {
    Ok(_) => test.fail("command and structured metadata drift was accepted")
    Err(_) => {}
  }
}

test test_leaves_absent_argument_unchanged {
  let text = " COMMAND = runner\n ARGV_COMMAND = x72756e6e6572\n"
  test.eq(muon.muon_rewrite_ninja_argument(text, "old", "new")?, text)
}

test test_muon_helper_changes_invalidate_each_consumer [fs, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "muon-helper-input")?
  fp"{root}/pm".mkdir(parents: true)?
  let helper = fp"{root}/pm/muon.xsh"
  helper.write("first\n")?
  let names = [
    "muon", "libinput", "foot-minimal", "wayland-dev", "wayland-libs-client", "wayland-libs-server",
    "wayland-libs-cursor", "wlroots0.20", "wl-clipboard", "libva",
  ]
  let checkout = fs.cwd()?
  let packages = [recipe.load_package(fp"{checkout}/packages/{name}")? for name in names]
  let before = [fingerprint.package_build_input(root, pkg, types.target_x86_64())? for pkg in packages]
  helper.write("second\n")?
  for index in range(0, packages.len()) {
    assert fingerprint.package_build_input(root, packages[index], types.target_x86_64())? != before[index]
  }
}


test test_rewrites_repeated_adjacent_arguments {
  let old = "old"
  let replacement = "new"
  let text = " COMMAND = old old\n ARGV_COMMAND = x6f6c64 x6f6c64\n"
  let expected = " COMMAND = new new\n ARGV_COMMAND = x6e6577 x6e6577\n"
  test.eq(muon.muon_rewrite_ninja_argument(text, old, replacement)?, expected)
}
