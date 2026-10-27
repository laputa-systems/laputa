##! Fresh installs seed the trust store from pinned package seeds.
use trust.store as trust_store
use trust.update as trust_update

proc stage_target(ctx: TestContext, name: Str) [fs, error] -> Result[Path, Error] {
  let root = test.temp_dir(ctx, name: name)?
  let seed_bundle = fp"{root}/usr/share/laputa/trust/seed/ca-certificates.crt"
  let seed_policy = fp"{root}/usr/share/laputa/trust/seed/trust-policy"
  let key_path = fp"{root}/etc/laputa/trust-update-key"
  for parent in [seed_bundle.parent, key_path.parent, fp"{root}/etc/ssl/certs"] {
    parent.mkdir(parents: true)
  }

  seed_bundle.write(p"packages/ca-certificates/files/cacert.pem".read_bytes()?)
  seed_policy.write(p"packages/ca-certificates/files/trust-policy".read_bytes()?)
  key_path.write(bytes.from_text("0123456789abcdef0123456789abcdef"))
  fp"{root}/etc/ssl/certs/ca-certificates.crt".symlink(to: p"../../../var/lib/laputa/trust/active/ca-certificates.crt")
  fp"{root}/etc/laputa/trust-policy".symlink(to: p"../../var/lib/laputa/trust/active/trust-policy")
  root
}

test installer_seeds_fresh_target_trust_from_package_seeds [fs, error] { |ctx|
  let root = stage_target(ctx, "installer trust seed")?
  let generation = trust_store.trust_store_bootstrap_from_seeds(root)?
  assert generation == "1"
  assert trust_store.trust_store_read_active(trust_store.trust_store_paths(root))? == "1"
  assert fp"{root}/var/lib/laputa/trust/accepted".read_text()? == "1\n"
}

test installer_seed_reports_functional_generation_one_status [fs, time, error] { |ctx|
  let root = stage_target(ctx, "installer trust status")?
  let _ = trust_store.trust_store_bootstrap_from_seeds(root)?
  let status = trust_update.trust_status(root)?
  assert status.generation == "1"
  assert status.provenance == "package-seed"
}

test installer_wires_trust_seeding_after_target_config [fs, error] {
  let setup = p"installer/setup-laputa.xsh".read_text()?
  assert "seed_target_trust_store(/mnt/target)" in setup
  let after_config = setup.split("write_target_config(/mnt/target")[1]
  assert "seed_target_trust_store(/mnt/target)" in after_config
}

test installer_image_ships_trust_modules [fs, error] {
  let builder = p"build-installer-image.xsh".read_text()?
  assert "/usr/bin/trust/{name}" in builder
  for name in ["key.xsh", "policy.xsh", "release.xsh", "store.xsh", "update.xsh"] {
    assert f"\"{name}\"" in builder
  }
}
