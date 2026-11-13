use pm.generation

proc verify_successor(root: Path, expected_tools: Path = p"/run/self-hosting-output/target/x86_64-unknown-linux-musl/verification", expected_os_release: Path? = null) [fs, process, env, error] -> Result[Unit, Error] {
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  let expected = generation.read_generation_receipt_file(fp"{root}/inputs/generation-B.json")?
  let previous = generation.read_generation_receipt_file(fp"{root}/inputs/generation-A.json")?
  let actual = generation.read_generation_receipt(p"/")?
  assert actual == expected
  assert actual.generation_sha256 != previous.generation_sha256
  assert actual.profile.name == "qemu-self-hosting"
  if expected_os_release != null {
    assert p"/etc/os-release".read_bytes()? == expected_os_release.read_bytes()?
    let before = previous.artifacts |> where .package_name == "baselayout" |> collect
    let after = actual.artifacts |> where .package_name == "baselayout" |> collect
    assert before.len() == 1 and after.len() == 1
    assert before[0].artifact_key != after[0].artifact_key
    let rebuilt_key = after[0].artifact_key
    print "LAPUTA_SELF_HOSTING_PACKAGE_REBUILT" $rebuilt_key
  }
  let output = p"/run/self-hosting-output"
  output.mkdir()?
  assert p"/sys/class/block/vdc/ro".read_text()?.trim() == "1"
  linux.mount(b"/dev/vdc", output, fstype: "ext4", options: ["ro", "noload", "nosuid", "nodev"])?
  for name in ["xsh", "xsht"] {
    assert hash.sha256(fp"/usr/bin/{name}")? == hash.sha256(fp"{expected_tools}/{name}")?
  }
  assert (run.text /usr/bin/cohort-c).trim() == "declared C payload"
  assert (run.text /usr/bin/cohort-rust).trim() == "declared Rust payload"
  assert p"/usr/share/cohort-xsh".read_text()? == "declared XSH payload\n"
  let identity = actual.generation_sha256
  print "LAPUTA_SELF_HOSTING_SUCCESSOR_BOOTED" $identity
}

proc main(root: Path, expected_tools: Path = p"/run/self-hosting-output/target/x86_64-unknown-linux-musl/verification", ...release_inputs: List[Str]) [fs, process, env, error] -> Result[Unit, Error] {
  guard release_inputs.len() <= 1 else { fail "expected at most one declared os-release input" }
  let release_input = if release_inputs.is_empty() { null } else { Path(release_inputs[0]) }
  verify_successor(root, expected_tools, release_input)?
}

main(@args)?
