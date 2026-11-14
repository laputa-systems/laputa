use installer.package_roots_host

test test_smoke_target_carries_the_firewall_that_oxish_needs {
  let production = package_roots_host.installer_target_roots("linux", false)
  let smoke = package_roots_host.installer_target_roots("linux", true)

  assert "oxish" not in production
  assert "crabtables" not in production
  assert smoke == production + ["oxish", "crabtables"]
}
