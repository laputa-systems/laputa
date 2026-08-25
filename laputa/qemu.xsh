##! Structured QEMU construction and supervision for qemu-dwl-foot.
use laputa.build as build
use laputa.image as image
use laputa.proof as proof
use laputa.types as types

## The host executable and QMP helper used by a QEMU invocation.
export type QemuConfig = {qemu: Path, python: Path, qmp_helper: Path}

## Return the stable root PARTUUID written by Laputa's GPT image module.
export pure root_partuuid() -> Str {
  image.image_root_partuuid()
}

## Build the required ARM serial console command line for a profile mode.
export pure kernel_cmdline(mode: types.QemuMode) -> Str {
  let base = f"earlycon=pl011,mmio,0x09000000 keep_bootcon console=ttyAMA0 ignore_loglevel devtmpfs.mount=1 root=PARTUUID=${root_partuuid()} rootfstype=ext4 rootwait rootdelay=2 rw init=/init loglevel=8 XSH_LINUX_REAL=1 XSH_UNIX_REAL=1"

  if mode == types.Test {
    return f"${base} LAPUTA_QEMU_DWL_FOOT_PROOF=1"
  }

  return base
}

## Resolve only the documented host-side QEMU configuration surface.
export proc qemu_config(laputa_root: Path) [fs, process, env, error] -> Result[QemuConfig] {
  let raw_qemu = (env.get("QEMU_SYSTEM_AARCH64") ?? "qemu-system-aarch64").trim()
  let qemu = if raw_qemu == "" { process.which("qemu-system-aarch64")? } else { fp"${raw_qemu}" }
  let python = process.which("python3")?
  let qmp_helper = fp"${laputa_root}/boot/qmp-proof.py"

  if ! fs.exists(qmp_helper)? {
    return Err(types.LaputaError.Profile(f"missing QMP helper ${qmp_helper}"))
  }

  {qemu, python, qmp_helper}
}

## Construct an exact QEMU argv without a shell command boundary.
export pure qemu_command_argv(
  value: QemuConfig,
  profile: types.SystemProfile,
  outputs: build.ProfileOutputs,
  mode: types.QemuMode,
) -> List[Str] {
  let display = if mode == types.Test {
    "none"
  } else {
    "cocoa,zoom-to-fit=on,show-cursor=on"
  }

  [
    value.qemu.display(),
    "-M",
    profile.qemu.machine,
    "-cpu",
    profile.qemu.cpu,
    "-smp",
    f"${profile.qemu.smp}",
    "-m",
    profile.qemu.memory,
    "-kernel",
    outputs.kernel.display(),
    "-append",
    kernel_cmdline(mode),
    "-drive",
    f"if=none,id=root,format=raw,file=${outputs.disk},snapshot=on",
    "-device",
    "virtio-blk-device,drive=root",
    "-netdev",
    "user,id=net0",
    "-device",
    "virtio-net-pci,netdev=net0",
    "-device",
    f"virtio-gpu-pci,xres=${profile.qemu.width},yres=${profile.qemu.height}",
    "-device",
    "virtio-keyboard-pci",
    "-device",
    "virtio-tablet-pci",
    "-device",
    "virtio-mouse-pci",
    "-qmp",
    f"unix:${outputs.qmp_socket},server,nowait",
    "-display",
    display,
    "-serial",
    "stdio",
    "-no-reboot",
  ]
}

# QEMU's managed handle owns the process group; cancel sends TERM, waits five
# seconds, then escalates that group to KILL and reaps it.  Do not replace this
# with a background shell watcher: it would lose the explicit cleanup boundary.
proc qemu_stop(launched: ProcessHandle) [process, error] {
  launched.cancel(signal: "TERM", kill_after: 5s)?
}

# Returns whether the spawned QEMU group leader is still live without a shell watcher.
proc qemu_process_live(pid: Int) [process, error] -> Result[Bool] {
  match process.kill(pid, signal: "0") {
    Ok(_) => true
    Err(_) => false
  }
}

# Invokes the retained focused Python QMP helper with structured arguments.
proc qemu_qmp(value: QemuConfig, mode: Str, socket: Path, screenshot: Path = p"") [process, error] {
  var argv = [value.python.display(), value.qmp_helper.display(), mode, socket.display()]
  if screenshot.display() != "" {
    argv = argv.push(screenshot.display())
  }

  let status = process.run(process.command_argv(value.python, argv))?
  if ! status.ok {
    return Err(types.LaputaError.Docker(f"QMP ${mode} helper failed"))
  }
}

# Retry idempotent QMP readiness or screenshot requests while QEMU publishes
# its socket.  Keyboard input is deliberately *not* retried: a late transport
# error could otherwise duplicate the proof keystrokes.
proc qemu_qmp_retry(value: QemuConfig, mode: Str, socket: Path, screenshot: Path = p"") [process, time, error] {
  var attempt = 0
  while attempt < 20 {
    match qemu_qmp(value, mode, socket, screenshot) {
      Ok(_) => return
      Err(_) => {
        time.sleep(250ms)?
        attempt += 1
      }
    }
  }

  return Err(types.LaputaError.Docker(f"QMP ${mode} helper did not become ready"))
}

## Combine QEMU's serial console and stderr log before scanning proof markers:
## fatal QEMU diagnostics can be emitted on stderr rather than serial.
export proc qemu_log_text(console_log: Path, qemu_log: Path) [fs, error] -> Result[Str] {
  let console = if fs.exists(console_log)? { fs.read_text(console_log)? } else { "" }
  let qemu = if fs.exists(qemu_log)? { fs.read_text(qemu_log)? } else { "" }
  f"${console}\n${qemu}"
}

## A screenshot is proof evidence only when QMP wrote nonempty image bytes.
export proc screenshot_is_valid(path_value: Path) [fs, error] -> Result[Bool] {
  fs.exists(path_value)? and fs.metadata(path_value)?.kind == "file" and fs.metadata(path_value)?.size > 0
}

pure qemu_output_locations(outputs: build.ProfileOutputs) -> Str {
  f"console=${outputs.console_log}; qemu-log=${outputs.qemu_log}; screenshot=${outputs.screenshot}"
}

## Run a bounded headless proof, inject input through QMP, and validate its output.
export proc run_test(value: QemuConfig, profile: types.SystemProfile, outputs: build.ProfileOutputs) [fs, process, time, error] {
  if ! fs.exists(outputs.kernel)? or ! fs.exists(outputs.disk)? {
    return Err(types.LaputaError.Profile("qemu-dwl-foot image is missing; run laputa build first"))
  }
  if profile.proof.input_text != "laputa" {
    return Err(types.LaputaError.Profile("qemu-dwl-foot QMP helper requires proof input laputa"))
  }

  fs.remove(outputs.console_log, missing_ok: true)?
  fs.remove(outputs.qemu_log, missing_ok: true)?
  fs.remove(outputs.qmp_socket, missing_ok: true)?
  fs.remove(outputs.screenshot, missing_ok: true)?
  let command = process.command_argv(
    value.qemu,
    qemu_command_argv(value, profile, outputs, types.Test),
    stdout: outputs.console_log,
    stderr: outputs.qemu_log,
  )
  let launched = spawn command?
  var elapsed = 0
  var injected = false
  var screenshot_taken = false

  while qemu_process_live(launched.pid)? {
    let log_text = qemu_log_text(outputs.console_log, outputs.qemu_log)?
    let failed = proof.failure_marker(profile.proof, log_text)
    if failed != "" {
      qemu_stop(launched)?
      return Err(types.LaputaError.Profile(f"QEMU proof failed with ${failed}; inspect ${qemu_output_locations(outputs)}"))
    }

    # READY is printed by the guest only after dwl has launched foot's reader.
    # This keeps exactly one deterministic `laputa` plus EOF QMP injection.
    if ! injected and fs.exists(outputs.qmp_socket)? and "LAPUTA_DWL_FOOT_PROOF_READY" in log_text {
      qemu_qmp_retry(value, "ready", outputs.qmp_socket)?
      qemu_qmp(value, "input", outputs.qmp_socket)?
      injected = true
    }

    if proof.succeeded(profile.proof, log_text) {
      if profile.proof.screenshot_required and ! screenshot_taken {
        qemu_qmp_retry(value, "screenshot", outputs.qmp_socket, outputs.screenshot)?
        screenshot_taken = true
      }

      qemu_stop(launched)?
      let final_log = qemu_log_text(outputs.console_log, outputs.qemu_log)?
      proof.verify_console(profile.proof, final_log)?
      if profile.proof.screenshot_required and ! screenshot_is_valid(outputs.screenshot)? {
        return Err(types.LaputaError.Profile(f"QMP did not create a nonempty screenshot; inspect ${qemu_output_locations(outputs)}"))
      }

      print "laputa test qemu-dwl-foot: ok"
      return
    }

    if elapsed >= 180 {
      qemu_stop(launched)?
      return Err(types.LaputaError.Profile(f"timed out waiting for qemu-dwl-foot proof; inspect ${qemu_output_locations(outputs)}"))
    }

    time.sleep(1s)?
    elapsed += 1
  }

  let _ = wait launched?
  let final_log = qemu_log_text(outputs.console_log, outputs.qemu_log)?
  match proof.verify_console(profile.proof, final_log) {
    Ok(_) => return Err(types.LaputaError.Profile(f"QEMU exited after guest proof before supervisor completion; inspect ${qemu_output_locations(outputs)}"))
    Err(_) => return Err(types.LaputaError.Profile(f"QEMU exited before qemu-dwl-foot proof; inspect ${qemu_output_locations(outputs)}"))
  }
}

## Run the profile's normal Cocoa session and return its real QEMU exit status.
export proc boot(value: QemuConfig, profile: types.SystemProfile, outputs: build.ProfileOutputs) [fs, process, error] {
  if ! fs.exists(outputs.kernel)? or ! fs.exists(outputs.disk)? {
    return Err(types.LaputaError.Profile("qemu-dwl-foot image is missing; run laputa build first"))
  }

  let status = process.run(process.command_argv(value.qemu, qemu_command_argv(value, profile, outputs, types.Interactive)))?
  if ! status.ok {
    return Err(types.LaputaError.Docker("interactive QEMU exited unsuccessfully"))
  }
}
