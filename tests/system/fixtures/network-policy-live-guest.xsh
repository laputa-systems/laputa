##! Qualify the live IPv4 and IPv6 applier inside the disposable self-hosting KVM guest.
use pm.generation

proc main(scope: Str) {
  assert scope == "disposable-vm", "live network qualification requires the disposable VM"
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  assert generation.read_generation_receipt(p"/")?.profile.name == "qemu-self-hosting"
  let repository = p"/mnt/self-hosting/inputs/laputa"
  assert repository.is_dir()?
  let xsht = process.which("xsht")?
  tempdir scratch {
    let stdout = fp"{scratch}/stdout"
    let stderr = fp"{scratch}/stderr"
    let command = process.command_argv(xsht, [xsht.display(), "test", "--jobs", "1", "--nocapture", "tests/system/network_policy_applier.xsh"], cwd: repository, stdout: stdout, stderr: stderr, timeout: 120s)
    let status = process.run(command)?
    let output = stdout.read_text()?
    let diagnostics = stderr.read_text()?
    io.write_stdout(output)
    io.write_stderr(diagnostics)
    assert status.exited_with(0), "live IPv4 and IPv6 qualification failed"
    assert "0 skipped" in output and "0 failed" in output, "the guest must execute every network qualification case"
    assert "NETWORK_APPLIER_OK" in output
    assert "NETWORK_WRITER_IDENTITIES controller=" in output + diagnostics
    assert "writer-distinct true" in output and "writer-completed true" in output
    assert " family=inet6" in output + diagnostics
    for line in ["writer6-distinct true", "writer6-completed true", "applied6 converged", "settled6 converged plans=0 attempts=0", "conflict6 reobserve plans=4 attempts=0", "recovered6 converged", "default6-metric-1024 true", "lost6 reobserve plans=2 attempts=0", "dup6-observation refused selected IPv6 address failed duplicate address detection"] {
      assert line in output, f"missing live IPv6 evidence: {line}"
    }
  }
  print "NETWORK_IPV4_LIVE_GUEST_OK"
  print "NETWORK_IPV6_LIVE_GUEST_OK"
}
