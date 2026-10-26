use pm.generation

proc main(root: Path) [fs, process, env, error] -> Result[Unit, Error] {
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  let expected = generation.read_generation_receipt_file(fp"{root}/inputs/generation-B.json")?
  let previous = generation.read_generation_receipt_file(fp"{root}/inputs/generation-A.json")?
  let actual = generation.read_generation_receipt(/)?
  assert actual == expected
  assert actual.generation_sha256 != previous.generation_sha256
  assert actual.profile.name == "qemu-self-hosting"
  let output = p"/run/self-hosting-output"
  output.mkdir()?
  linux.mount(b"/dev/vdc", output, fstype: "ext4", options: ["ro", "nosuid", "nodev"])?
  for name in ["xsh", "xsht"] {
    assert hash.sha256(fp"/usr/bin/{name}")? == hash.sha256(fp"{output}/target/x86_64-unknown-linux-musl/verification/{name}")?
  }
  assert (run.text /usr/bin/cohort-c).trim() == "declared C payload"
  assert (run.text /usr/bin/cohort-rust).trim() == "declared Rust payload"
  assert p"/usr/share/cohort-xsh".read_text()? == "declared XSH payload\n"
  let identity = actual.generation_sha256
  print "LAPUTA_SELF_HOSTING_SUCCESSOR_BOOTED" $identity
}

main(@args)?
