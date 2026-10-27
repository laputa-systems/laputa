##! Composed images carry factory trust state for profiles that include the
##! CA package, so first boot has readable CA roots and distrust policy.
use pm.generation as pm_generation
use system.container_build as container_build

proc seed_overlay(ctx: TestContext, name: Str) [fs, error] -> Result[Path, Error] {
  let overlay = test.temp_dir(ctx, name: name)?
  container_build.container_seed_overlay_trust_store(
    overlay,
    p"packages/ca-certificates/files/cacert.pem",
    p"packages/ca-certificates/files/trust-policy",
  )?
  overlay
}

test image_overlay_trust_seed_matches_pinned_seeds [fs, error] { |ctx|
  let overlay = seed_overlay(ctx, "image trust seed")?
  let generations = fp"{overlay}/var/lib/laputa/trust/generations/1"
  assert fp"{generations}/ca-certificates.crt".read_bytes()? == p"packages/ca-certificates/files/cacert.pem".read_bytes()?
  assert fp"{generations}/trust-policy".read_bytes()? == p"packages/ca-certificates/files/trust-policy".read_bytes()?
  assert fp"{generations}/owner".read_text()? == "package-seed\n"
  assert fp"{overlay}/var/lib/laputa/trust/accepted".read_text()? == "1\n"
  assert fp"{overlay}/var/lib/laputa/trust/active".readlink()? == p"generations/1"
  let _ = pm_generation.overlay_digest(overlay)?
}

test image_prepare_overlay_seeds_only_ca_profiles [fs, error] {
  let source = p"system/container_build.xsh".read_text()?
  assert "container_seed_overlay_trust_store(" in source
  assert "\"ca-certificates\" in profile.package_roots" in source
}
