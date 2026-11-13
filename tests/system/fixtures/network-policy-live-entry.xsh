##! Overlay declared matching tools using only the canonical root's built-in JSON boundary.

type BootstrapIdentity = {format: Str, profile: Str, target: Str, generation_sha256: Str}

proc bootstrap_identity(receipt_path: Path, cmdline: Str) -> Result[BootstrapIdentity, Error] {
  let receipt = json.read(receipt_path)?.require(BootstrapIdentity)?
  assert receipt.format == "laputa-generation-1", "bootstrap requires the canonical receipt format"
  assert receipt.profile == "qemu-self-hosting", "bootstrap requires the canonical self-hosting profile"
  assert receipt.target == "x86_64-linux-musl", "bootstrap requires the canonical target"
  assert receipt.generation_sha256 == "906009468ffe783b2078aacfe5f1002e7294a15ac57712e50a2d09766229a8a5", "bootstrap requires canonical A"
  assert "LAPUTA_SELF_HOSTING=1" in cmdline.trim().split(" "), "bootstrap requires the disposable VM kernel token"
  receipt
}

proc bootstrap(root: Path) {
  let receipt = bootstrap_identity(p"/var/lib/laputa/generation.json", p"/proc/cmdline".read_text()?)?
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
  let source = fp"{repository}/tests/system/fixtures/network-policy-live-verify.xsh"
  unix.exec(process.command_argv(p"/usr/bin/xsh", ["xsh", source.display(), root.display()], cwd: repository, env: {
    XSH_ROOT: "/usr/lib/xsh",
    XSH_HOST: "/usr/bin/xsh",
    XSH_MODULE_PATH: f"{repository}:/usr/lib/xsh/core",
    TMPDIR: "/tmp",
    PATH: f"{tools}/bin:/usr/bin:/bin",
  }))
}

proc main(...argv: List[Str]) {
  assert argv.len() == 1
  bootstrap(fp"{argv[0]}")
}
