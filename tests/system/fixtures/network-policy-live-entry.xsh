##! Overlay declared matching tools on a private canonical root, then execute the live-network witness.
use pm.generation

proc bootstrap(root: Path) {
  let receipt = generation.read_generation_receipt(p"/")?
  assert receipt.profile.name == "qemu-self-hosting"
  assert receipt.generation_sha256 == "906009468ffe783b2078aacfe5f1002e7294a15ac57712e50a2d09766229a8a5"
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  let tools = fp"{root}/tools"
  for name in ["xsh", "xsht"] {
    let staged = fp"/usr/bin/{name}-qualification"
    fs.install(fp"{tools}/bin/{name}", staged, 0o755)
    staged.rename(to: fp"/usr/bin/{name}", overwrite: true)
    assert hash.sha256(fp"{tools}/bin/{name}")? == hash.sha256(fp"/usr/bin/{name}")?
  }
  p"/usr/lib/xsh/core".remove()
  let _ = fs.copy_tree(fp"{tools}/core", p"/usr/lib/xsh/core", overwrite: true)?
  print "NETWORK_GUEST_CANONICAL_ROOT_WITH_TOOL_OVERLAY" $receipt.generation_sha256
  print "NETWORK_GUEST_XSH_SHA256" ${hash.sha256(p"/usr/bin/xsh")?.hex()}
  print "NETWORK_GUEST_XSHT_SHA256" ${hash.sha256(p"/usr/bin/xsht")?.hex()}
  let repository = fp"{root}/inputs/laputa"
  let source = fp"{repository}/tests/system/fixtures/network-policy-live-entry.xsh"
  unix.exec(process.command_argv(p"/usr/bin/xsh", ["xsh", source.display(), root.display(), "verify"], cwd: repository, env: {
    XSH_ROOT: "/usr/lib/xsh",
    XSH_HOST: "/usr/bin/xsh",
    XSH_MODULE_PATH: f"{repository}:/usr/lib/xsh/core",
    TMPDIR: "/tmp",
    PATH: f"{tools}/bin:/usr/bin:/bin",
  }))
}

proc verify(root: Path) {
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

proc main(...argv: List[Str]) {
  assert argv.len() == 1 or (argv.len() == 2 and argv[1] == "verify")
  if argv.len() == 1 {
    bootstrap(fp"{argv[0]}")
  } else {
    verify(fp"{argv[0]}")
  }
}
