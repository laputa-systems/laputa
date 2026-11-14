test test_live_network_host_accepts_only_complete_raw_console_marker_lines [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "network-live-markers")?
  let source = p"tests/system/fixtures/network-policy-live-host.xsh".read_text()?
  let entry = "proc main(...argv: List[Str])"
  assert source.split(entry).len() == 2
  let checks = r"""
let paths = build.outputs(Path(args[0]))
let markers = ["NETWORK_LIVE_KVM_OK", "NETWORK_IPV4_LIVE_GUEST_OK", "NETWORK_IPV6_LIVE_GUEST_OK", "NETWORK_GUEST_CORE_OVERLAY_HASHES_OK", "NETWORK_APPLIER_OK"]
let writer = "NETWORK_WRITER_IDENTITIES controller=84 writer=86 namespace=net:[4026532334]"
let genuine = markers.join("\n") + "\n" + writer + "\n"
paths.qemu_log.write(genuine)
paths.console_log.write("")
assert !live_proof_complete(paths)?, "QEMU diagnostics cannot complete the proof"
paths.console_log.write([f"error: quoted '{marker}'" for marker in markers].join("\n") + "\nerror: " + writer + "\n")
assert !live_proof_complete(paths)?, "embedded or quoted markers cannot complete the proof"
paths.console_log.write(markers.join("\n") + "\nsource: " + writer + "\n")
assert !live_proof_complete(paths)?, "writer identity must start its console line"
paths.console_log.write(markers.join("\n") + "\n" + writer)
assert !live_proof_complete(paths)?, "unterminated writer identity is not a complete line"
paths.console_log.write(genuine.replace("NETWORK_LIVE_KVM_OK\n", with: "") + "NETWORK_LIVE_KVM_OK")
assert !live_proof_complete(paths)?, "unterminated completion marker is not a complete line"
paths.console_log.write(genuine)
assert live_proof_complete(paths)?
paths.console_log.write(genuine.replace("\n", with: "\r\n"))
assert live_proof_complete(paths)?, "serial CRLF terminators remain valid"
print "raw-console-only"
"""
  let result = test.run_xsh(ctx, source.replace(entry, with: "proc unused_main(...argv: List[Str])") + checks, [], [root.display()], {}, name: "network-live-markers.xsh")?
  assert result.success, result.stderr
  assert result.stdout == "raw-console-only\n"
}

test test_live_network_bootstrap_uses_builtin_json_and_exact_canonical_guards [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "network-live-bootstrap")?
  let source = p"tests/system/fixtures/network-policy-live-entry.xsh".read_text()?
  let entry = "proc main(...argv: List[Str])"
  assert source.split(entry).len() == 2
  assert "use pm." not in source
  let driver = source.replace(entry, with: "proc unused_main(...argv: List[Str])") + r"""
let identity = bootstrap_identity(Path(args[0]), args[1])?
assert identity.profile == "qemu-self-hosting"
print "canonical-identity"
"""
  let original = p"tests/system/fixtures/network-policy-live-generation.json".read_text()?
  let receipt = fp"{root}/generation.json"
  receipt.write(original)
  let cmdline = "console=ttyS0 LAPUTA_SELF_HOSTING=1\n"
  let valid = test.run_xsh(ctx, driver, [], [receipt.display(), cmdline], {}, name: "bootstrap-identity.xsh")?
  assert valid.success and valid.stdout == "canonical-identity\n", valid.stderr
  for change in [
    {before: "laputa-generation-1", after: "unknown", expected: "canonical receipt format"},
    {before: "qemu-self-hosting", after: "other-profile", expected: "canonical self-hosting profile"},
    {before: "x86_64-linux-musl", after: "other-target", expected: "canonical target"},
    {before: "906009468ffe783b2078aacfe5f1002e7294a15ac57712e50a2d09766229a8a5", after: "wrong-generation", expected: "canonical A"},
  ] {
    assert original.split(change.before).len() == 2
    receipt.write(original.replace(change.before, with: change.after))
    let refused = test.run_xsh(ctx, driver, [], [receipt.display(), cmdline], {}, name: "bootstrap-refused.xsh")?
    assert !refused.success and change.expected in refused.stderr, refused.stderr
  }
  receipt.write(original)
  for bad_cmdline in ["", "prefixLAPUTA_SELF_HOSTING=1", "LAPUTA_SELF_HOSTING=10"] {
    let refused = test.run_xsh(ctx, driver, [], [receipt.display(), bad_cmdline], {}, name: "bootstrap-cmdline.xsh")?
    assert !refused.success and "disposable VM kernel token" in refused.stderr, refused.stderr
  }
}

test test_live_network_final_reader_validates_more_than_bootstrap_identity [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "network-live-full-receipt")?
  let original = p"tests/system/fixtures/network-policy-live-generation.json".read_text()?
  let receipt = fp"{root}/generation.json"
  receipt.write(original)
  let driver = r"""use pm.generation
let receipt = generation.read_generation_receipt_file(Path(args[0]))?
assert receipt.profile.name == "qemu-self-hosting"
assert receipt.generation_sha256 == "906009468ffe783b2078aacfe5f1002e7294a15ac57712e50a2d09766229a8a5"
print "full-receipt"
"""
  let valid = test.run_xsh(ctx, driver, [], [receipt.display()], {}, name: "final-receipt.xsh")?
  assert valid.success and valid.stdout == "full-receipt\n", valid.stderr
  let root_hash = "cacd9743b4a802722e6e3dab67c536e76f08ac2b1fe0d4067125d26e542c9f88"
  assert original.split(root_hash).len() == 2
  receipt.write(original.replace(root_hash, with: "not-a-sha256"))
  let refused = test.run_xsh(ctx, driver, [], [receipt.display()], {}, name: "final-receipt-refused.xsh")?
  assert !refused.success and "generation root_sha256" in refused.stderr, refused.stderr
}
