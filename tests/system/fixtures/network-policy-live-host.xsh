##! Own one bounded QEMU run of the disposable live-network qualification.
use system.build
use system.profile
use system.qemu
use system.types

pure complete_marker(console: Str, marker: Str) -> Bool {
  let lines = console.split("\n")
  for line in lines[0..lines.len() - 1] {
    return true when line == marker or line == f"{marker}\r"
  }
  false
}

proc live_proof_complete(paths: build.ProfileOutputs) -> Result[Bool, Error] {
  return false unless paths.console_log.exists()?
  let console = paths.console_log.read_text()?
  for marker in ["NETWORK_LIVE_KVM_OK", "NETWORK_IPV4_LIVE_GUEST_OK", "NETWORK_GUEST_CORE_OVERLAY_HASHES_OK", "NETWORK_APPLIER_OK"] {
    return false unless complete_marker(console, marker)
  }
  let lines = console.split("\n")
  for line in lines[0..lines.len() - 1] {
    return true when line.starts_with("NETWORK_WRITER_IDENTITIES controller=")
  }
  false
}

proc qualify(repository: Path, output: Path) {
  let base = profile.load_system_profile("qemu-self-hosting", fp"{repository}/profiles")?
  let intent = {...base, qemu_smp: 2, qemu_memory: "4G"}
  let config = qemu.qemu_config(qemu.host_qemu_target()?)?
  let paths = {...build.outputs(output), qmp_socket: p"qmp.sock"}
  var argv = qemu.qemu_command_argv(config, intent, paths, types.Test)
  var index = 0
  while index < argv.len() {
    if argv[index] == "-append" {
      argv[index + 1] += " LAPUTA_SELF_HOSTING=1"
    }
    index += 1
  }
  argv += qemu.qemu_self_hosting_disks_argv(config.target, fp"{output}/inputs.ext4", fp"{output}/output.ext4")
  let child = spawn process.command_argv(config.qemu, argv, cwd: output, env: {TMPDIR: output.display()}, stdout: paths.console_log, stderr: paths.qemu_log)?
  defer child.cancel(signal: "TERM", kill_after: 5s)
  let started = time.monotonic()?
  while true {
    let ended = process.wait_timeout([child], timeout: 100ms)?
    assert ended == null, "guest exited before the live-network proof completed"
    let log = qemu.qemu_log_text(paths.console_log, paths.qemu_log)?
    assert "LAPUTA_SELF_HOSTING_FAILED" not in log and "Kernel panic" not in log, "live-network guest failed"
    if live_proof_complete(paths)? {
      print "NETWORK_LIVE_KVM_HOST_OK"
      return
    }
    assert time.monotonic()? - started < 300000000000, "live-network guest deadline exceeded"
  }
}

proc main(...argv: List[Str]) {
  assert argv.len() == 2
  qualify(fp"{argv[0]}", fp"{argv[1]}")
}
