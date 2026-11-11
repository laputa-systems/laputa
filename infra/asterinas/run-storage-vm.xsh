#!/bin/xsh --
use system.qemu

pure guest_failed(output: Str) -> Bool {
  "LAPUTA_ASTERINAS_TEST_FAILED" in output
    or "Kernel panic" in output
    or "panicked at" in output
    or "Uncaught panic" in output
    or "Heap allocation error" in output
}

proc process_live(pid: Int) [process, error] -> Result[Bool] {
  for entry in process.list()? |> where .pid == pid {
    return entry.status != "Z"
  }
  false
}

proc log_text(console_log: Path, backend_log: Path) [fs, error] -> Result[Str, Error] {
  let console = if console_log.exists() { console_log.read_text()? } else { "" }
  let backend = if backend_log.exists() { backend_log.read_text()? } else { "" }
  f"""{console}
{backend}"""
}

cli main(
  kind: Str,
  firecracker: Str,
  config: Str,
  kernel: Str,
  initramfs: Str,
  root: Str,
  state: Str,
  console: Path,
  backend_log: Path,
  kill_marker: Str,
  timeout_seconds: Int,
  memory_mib: Int = 1024,
) [fs, process, time, env, error] {
  guard kind == "firecracker" or kind == "qemu" else { fail f"storage runner: unknown kind {kind}" }
  console.remove()
  backend_log.remove()

  var argv: List[Str] = []
  if kind == "firecracker" {
    argv = [firecracker, "--no-api", "--config-file", config]
  } else {
    let target = qemu.host_qemu_target()?
    let value = qemu.qemu_config(target)?
    let input = qemu.QemuAsterinasReference(
      kernel: fp"{kernel}",
      initramfs: fp"{initramfs}",
      disk: fp"{root}",
      memory_mib: memory_mib,
      data_disk: qemu.DataDisk(fp"{state}"),
      network: qemu.NoNetwork,
      control: qemu.NoControl,
    )
    argv = qemu.qemu_asterinas_reference_argv(value, input)?
  }

  let launched = spawn process.command_argv(fp"{argv[0]}", argv, stdout: console, stderr: backend_log)?
  defer launched.cancel(signal: "KILL", kill_after: 0ms)

  let deadline_start = time.monotonic()?
  var deadline = deadline_start + timeout_seconds * 1000000000
  var completed = false
  var killed = false
  while process_live(launched.pid)? {
    let output = log_text(console, backend_log)?
    guard !guest_failed(output) else { fail "storage guest reported a kernel or proof failure" }
    if kill_marker != "" {
      guard !("LAPUTA_ASTERINAS_TEST_OK" in output) else {
        fail "storage guest finished before its kill marker"
      }
      if kill_marker in output {
        launched.cancel(signal: "KILL", kill_after: 0ms)?
        killed = true
        break
      }
    } else if "LAPUTA_ASTERINAS_TEST_OK" in output and !completed {
      completed = true
      deadline = time.monotonic()? + 60 * 1000000000
    }
    if time.monotonic()? >= deadline {
      fail "storage guest timed out"
    }
    time.sleep(50ms)?
  }

  if killed {
    print "STORAGE_VMM_KILLED"
    return
  }

  let status = wait launched?
  let output = log_text(console, backend_log)?
  guard !guest_failed(output) else { fail "storage guest reported a kernel or proof failure" }
  guard "LAPUTA_ASTERINAS_TEST_OK" in output else {
    fail "storage guest exited before its completion marker"
  }
  guard status.ok else { fail "storage guest powered off with a failing VMM status" }
}
