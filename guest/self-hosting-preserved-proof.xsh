use pm.generation

proc main(root: Path) [fs, process, env, error] -> Result[Unit, Error] {
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  let expected = generation.read_generation_receipt_file(fp"{root}/inputs/generation-A.json")?
  assert generation.read_generation_receipt(/)? == expected
  for name in ["xsh", "xsht"] {
    assert hash.sha256(fp"/usr/bin/{name}")? == hash.sha256(fp"{root}/inputs/seed-A/{name}")?
  }
  print "LAPUTA_SELF_HOSTING_PREVIOUS_BOOTED" $expected.generation_sha256
}

main(@args)?
