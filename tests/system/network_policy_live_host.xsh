test test_live_network_host_accepts_only_complete_raw_console_marker_lines [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "network-live-markers")?
  let source = p"tests/system/fixtures/network-policy-live-host.xsh".read_text()?
  let entry = "proc main(...argv: List[Str])"
  assert source.split(entry).len() == 2
  let checks = r"""
let paths = build.outputs(Path(args[0]))
let markers = ["NETWORK_LIVE_KVM_OK", "NETWORK_IPV4_LIVE_GUEST_OK", "NETWORK_GUEST_CORE_OVERLAY_HASHES_OK", "NETWORK_APPLIER_OK"]
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
