test an_installed_tree_runs_from_its_own_prefix_and_ships_no_test_material { |ctx|
  let prefix = test.temp_dir(ctx)?
  run xsh packaging/install.xsh $prefix
  let entry = fp"{prefix}/bin/xinfra"
  let help = run.capture --text xsh $entry --help
  assert help.status.exit_code()? == 0
  assert "plan" in help.stdout and "apply" in help.stdout

  let shipped = fs.walk(fp"{prefix}/share/xinfra")? |> map { |item| item.path.display().replace(f"{prefix}", with: "") } |> collect()
  for forbidden in ["tests", "fixtures", "examples", ".work", ".git", "id_ed25519", "client", ".pub", "AGENTS.md"] {
    let hits = shipped |> where { |name| forbidden in name } |> count()
    assert hits == 0, f"{forbidden} was installed"
  }
}
