use system.build
use system.profile
use system.qemu
use system.types

proc main(repository: Path, output_root: Path, completion_marker: Str) [fs, process, env, time, io, error] -> Result[Unit, Error] {
  let intent = profile.load_system_profile("qemu-self-hosting", fp"{repository}/profiles")?
  let config = qemu.qemu_config(repository, qemu.host_qemu_target()?)?
  let outputs = {...build.outputs(output_root), qmp_socket: p"qmp.sock"}
  outputs.console_log.remove()
  outputs.qemu_log.remove()
  fp"{output_root}/qmp.sock".remove()
  var argv = qemu.qemu_command_argv(config, intent, outputs, types.Test)
  var index = 0
  while index < argv.len() {
    if argv[index] == "-append" {
      argv[index + 1] += " LAPUTA_SELF_HOSTING=1"
    }
    index += 1
  }
  argv += qemu.qemu_self_hosting_disks_argv(config.target, fp"{output_root}/inputs.ext4", fp"{output_root}/output.ext4")
  let child = spawn process.command_argv(config.qemu, argv, output_root, env: {TMPDIR: output_root.display()}, stdout: outputs.console_log, stderr: outputs.qemu_log)?
  defer child.cancel(signal: "TERM", kill_after: 5s)
  let start = time.monotonic()?
  var paused = false
  while true {
    let completed = process.wait_timeout([child], timeout: 50ms)?
    fail "QEMU exited before completing the guest proof" when completed != null
    let log = qemu.qemu_log_text(outputs.console_log, outputs.qemu_log)?
    if "LAPUTA_SELF_HOSTING_FAILED" in log or "Kernel panic" in log {
      fail f"guest failed; inspect {outputs.console_log} and {outputs.qemu_log}"
    }
    if ! paused and "LAP27_PAUSE_READY" in log {
      let stopped = process.run(process.command_argv(config.python, [config.python.display(), config.qmp_helper.display(), "stop", outputs.qmp_socket.display()], output_root, timeout: 5s))?
      fail "guest pause command failed" unless stopped.ok
      print "LAP27_HOST_PAUSED"
      io.flush_stdout()?
      fail "guest resume marker preceded the QMP stop acknowledgment" when "LAP27_RESUME_OBSERVED" in qemu.qemu_log_text(outputs.console_log, outputs.qemu_log)?
      time.sleep(3s)
      let resumed = process.run(process.command_argv(config.python, [config.python.display(), config.qmp_helper.display(), "cont", outputs.qmp_socket.display()], output_root, timeout: 5s))?
      fail "guest resume command failed" unless resumed.ok
      print "LAP27_HOST_RESUMED"
      io.flush_stdout()?
      paused = true
    }
    if completion_marker in log {
      print "in-guest proof completed"
      return
    }
    fail f"guest deadline exceeded; inspect {outputs.console_log}" when time.monotonic()? - start >= 3600 * 1000 * 1000 * 1000
  }
}

main(@args)?
