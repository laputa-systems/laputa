use system.build
use system.profile
use system.qemu
use system.types

proc main(repository: Path, output: Path, socket: Path) [fs, process, net, env, time, error] {
  assert output.normalize().starts_with(fp"{repository}/.work".normalize())
  assert "/.work/" in socket.normalize().display()
  let intent = profile.load_system_profile("qemu-self-hosting", fp"{repository}/profiles")?
  assert intent.qemu_smp == 2 and intent.qemu_memory == "4G"
  let config = qemu.qemu_config(qemu.host_qemu_target()?)?
  let paths = {...build.outputs(output), qmp_socket: socket}
  paths.console_log.remove()
  paths.qemu_log.remove()
  socket.remove()
  defer socket.remove()
  var argv = qemu.qemu_command_argv(config, intent, paths, types.Test)
  for index in range(argv.len()) {
    if argv[index] == "-append" { argv[index + 1] += " LAPUTA_SELF_HOSTING=1" }
    if argv[index] == "-netdev" { argv[index + 1] = "user,id=net0,restrict=on" }
  }
  argv += qemu.qemu_self_hosting_disks_argv(config.target, fp"{output}/inputs.ext4", fp"{output}/output.ext4")
  let child = spawn process.command_argv(config.qemu, argv, output, env: {TMPDIR: output.display()}, stdout: paths.console_log, stderr: paths.qemu_log)?
  defer child.cancel(signal: "TERM", kill_after: 5s)
  let start = time.monotonic()?
  var paused = false
  while true {
    let completed = process.wait_timeout([child], timeout: 50ms)?
    fail "QEMU exited before the guest proof" when completed != null
    let log = qemu.qemu_log_text(paths.console_log, paths.qemu_log)?
    fail f"guest failed; inspect {paths.console_log}" when "LAPUTA_SELF_HOSTING_FAILED" in log or "Kernel panic" in log
    if ! paused and "NTP_PAUSE_READY" in log {
      qemu.qemu_control(socket, qemu.QemuStop)?
      fail "guest resumed before the QMP stop acknowledgment" when "NTP_RESUME_OBSERVED" in qemu.qemu_log_text(paths.console_log, paths.qemu_log)?
      time.sleep(3s)
      qemu.qemu_control(socket, qemu.QemuContinue)?
      paused = true
    }
    if "LAPUTA_NTP_GUEST_OK" in log {
      print "in-guest NTP proof completed"
      return
    }
    fail f"guest deadline exceeded; inspect {paths.console_log}" when time.monotonic()? - start >= 180 * 1000 * 1000 * 1000
  }
}

main(@args)?
