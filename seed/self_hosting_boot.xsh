use system.build
use system.activation
use system.launcher
use system.self_hosting
use system.profile
use system.qemu
use system.types

proc record_failed_pending(state: Path) [fs, time, error] {
  let record = activation.activation_status(state)?
  if record.pending != null { activation.activation_boot_failed(state)? }
}

proc main(repository: Path, output_root: Path, completion_marker: Str) [fs, process, net, env, time, io, error] -> Result[Unit, Error] {
  let declared = profile.load_system_profile("qemu-self-hosting", fp"{repository}/profiles")?
  let runtime_proof = completion_marker in ["LAPUTA_SELF_HOSTING_SUCCESSOR_BOOTED", "LAPUTA_SELF_HOSTING_PREVIOUS_BOOTED"]
  let intent = if runtime_proof { {...declared, qemu_memory: "4G"} } else { declared }
  let config = qemu.qemu_config(qemu.host_qemu_target()?)?
  let outputs = build.outputs(output_root)
  outputs.console_log.remove()
  outputs.qemu_log.remove()
  outputs.qmp_socket.remove()
  defer outputs.qmp_socket.remove()
  let generations = launcher.launcher_state(output_root)?
  var argv = qemu.boot_command_argv(config, intent, outputs, types.Test, generations)?
  var proof_complete = false
  defer {
    if ! proof_complete and generations != null {
      match record_failed_pending(generations) {
        Ok(_) => {}
        Err(problem) => { print "cannot record self-hosting boot failure:" $problem.message }
      }
    }
  }
  var index = 0
  while index < argv.len() {
    if argv[index] == "-append" {
      argv[index + 1] += " LAPUTA_SELF_HOSTING=1"
    }
    index += 1
  }
  let output_access = if runtime_proof { qemu.InspectOutput } else { qemu.BuildOutput }
  argv += qemu.qemu_self_hosting_disks_argv(config.target, fp"{output_root}/inputs.ext4", fp"{output_root}/output.ext4", output_access)
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
      qemu.qemu_control(outputs.qmp_socket, qemu.QemuStop)?
      print "LAP27_HOST_PAUSED"
      io.flush_stdout()?
      fail "guest resume marker preceded the QMP stop acknowledgment" when "LAP27_RESUME_OBSERVED" in qemu.qemu_log_text(outputs.console_log, outputs.qemu_log)?
      time.sleep(3s)
      qemu.qemu_control(outputs.qmp_socket, qemu.QemuContinue)?
      print "LAP27_HOST_RESUMED"
      io.flush_stdout()?
      paused = true
    }
    if completion_marker in log and (generations == null or "LAPUTA_SELF_HOSTING_ACTIVATION " in log) {
      var observed = true
      if generations != null {
        let record = activation.activation_status(generations)?
        let expected = if record.pending == null { record.current } else { record.pending }
        observed = self_hosting.self_hosting_boot_report_complete(outputs.console_log, expected, record.boot_serial)?
      }
      if observed {
        proof_complete = true
        print "in-guest proof completed"
        return
      }
    }
    fail f"guest deadline exceeded; inspect {outputs.console_log}" when time.monotonic()? - start >= 3600 * 1000 * 1000 * 1000
  }
}

main(@args)?
