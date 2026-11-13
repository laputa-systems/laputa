##! Validate the full receipt with the replacement interpreter before the live-network witness.
use pm.generation

proc main(...argv: List[Str]) {
  assert argv.len() == 1
  let root = fp"{argv[0]}"
  let receipt = generation.read_generation_receipt(p"/")?
  assert receipt.profile.name == "qemu-self-hosting"
  assert receipt.generation_sha256 == "906009468ffe783b2078aacfe5f1002e7294a15ac57712e50a2d09766229a8a5"
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  print "NETWORK_GUEST_PM_RECEIPT_VALIDATED"
  let tools = fp"{root}/tools"
  for name in ["xsh", "xsht"] {
    assert hash.sha256(fp"{tools}/bin/{name}")? == hash.sha256(fp"/usr/bin/{name}")?
  }
  for file in fs.files(fp"{tools}/core", hidden: true)? {
    let relative = file.path.relative_to(fp"{tools}/core")
    assert hash.sha256(file.path)? == hash.sha256(fp"/usr/lib/xsh/core/{relative}")?
  }
  print "NETWORK_GUEST_CORE_OVERLAY_HASHES_OK"
  let source = fp"{root}/inputs/laputa/tests/system/fixtures/network-policy-live-guest.xsh"
  let status = process.run(process.command_argv(p"/usr/bin/xsh", ["xsh", source.display(), "disposable-vm"], timeout: 180s))?
  assert status.exited_with(0), "live-network guest fixture failed"
  print "NETWORK_LIVE_KVM_OK"
}
