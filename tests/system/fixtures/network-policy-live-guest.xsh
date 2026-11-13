##! Qualify the live IPv4 applier inside the disposable self-hosting KVM guest.
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
    assert status.exited_with(0), "live IPv4 qualification failed"
    assert "0 skipped" in output and "0 failed" in output, "the guest must execute every network qualification case"
    assert "NETWORK_APPLIER_OK" in output
    assert "NETWORK_WRITER_IDENTITIES controller=" in output + diagnostics
    assert "writer-distinct true" in output and "writer-completed true" in output
  }
  print "NETWORK_IPV4_LIVE_GUEST_OK"
}
