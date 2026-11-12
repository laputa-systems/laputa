use pm.generation

proc verify_previous(root: Path, expected_os_release: Path? = null) [fs, process, env, error] -> Result[Unit, Error] {
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  let expected = generation.read_generation_receipt_file(fp"{root}/inputs/generation-A.json")?
  assert generation.read_generation_receipt(p"/")? == expected
  if expected_os_release != null { assert p"/etc/os-release".read_bytes()? == expected_os_release.read_bytes()? }
  for name in ["xsh", "xsht"] {
    assert hash.sha256(fp"/usr/bin/{name}")? == hash.sha256(fp"{root}/inputs/seed-A/{name}")?
  }
  print "LAPUTA_SELF_HOSTING_PREVIOUS_BOOTED" $expected.generation_sha256
}

proc main(root: Path, ...release_inputs: List[Str]) [fs, process, env, error] -> Result[Unit, Error] {
  guard release_inputs.len() <= 1 else { fail "expected at most one declared os-release input" }
  let release_input = if release_inputs.is_empty() { null } else { Path(release_inputs[0]) }
  verify_previous(root, release_input)?
}

main(@args)?
