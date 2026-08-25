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

  match mode {
    Test => f"${base} LAPUTA_QEMU_DWL_FOOT_PROOF=1"
    Interactive => base
  }
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
  let display = match mode {
    Test => "none"
    Interactive => "cocoa,zoom-to-fit=on,show-cursor=on"
  }
  let session = match mode {
    Test => profile.session.proof_argv
    Interactive => profile.session.interactive_argv
  }
  let _ = session

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

# Returns whether the spawned QEMU process is still live without a shell watcher.
proc process_live(kill: Path, pid: Int, cwd: Path) [process, error] -> Result[Bool] {
  process.run(process.command_argv(kill, ["kill", "-0", f"${pid}"], cwd))?.ok
}

# Invokes the retained focused Python QMP helper with structured arguments.
proc qmp(value: QemuConfig, mode: Str, socket: Path, screenshot: Path = p"") [process, error] {
  var argv = [value.python.display(), value.qmp_helper.display(), mode, socket.display()]
  if screenshot.display() != "" {
    argv = argv.push(screenshot.display())
  }

  let status = process.run(process.command_argv(value.python, argv))?
  if ! status.ok {
    return Err(types.LaputaError.Docker(f"QMP ${mode} helper failed"))
  }
}

## Run a bounded headless proof, inject input through QMP, and validate its output.
export proc run_test(value: QemuConfig, profile: types.SystemProfile, outputs: build.ProfileOutputs) [fs, process, time, error] {
  if ! fs.exists(outputs.kernel)? or ! fs.exists(outputs.disk)? {
    return Err(types.LaputaError.Profile("qemu-dwl-foot image is missing; run laputa build first"))
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
  let launched = process.spawn(command)?
  let kill = process.which("kill")?
  var elapsed = 0
  var injected = false
  var screenshot_taken = false

  while process_live(kill, launched.pid, outputs.root)? {
    let console = if fs.exists(outputs.console_log)? { fs.read_text(outputs.console_log)? } else { "" }
    let failed = proof.failure_marker(profile.proof, console)
    if failed != "" {
      let _ = process.kill(launched.pid, signal: "TERM")
      return Err(types.LaputaError.Profile(f"QEMU proof failed with ${failed}; inspect ${outputs.console_log}"))
    }

    if ! injected and fs.exists(outputs.qmp_socket)? and "LAPUTA_DWL_FOOT_PROOF_READY" in console {
      qmp(value, "input", outputs.qmp_socket)?
      injected = true
    }

    if proof.succeeded(profile.proof, console) {
      if profile.proof.screenshot_required and ! screenshot_taken {
        qmp(value, "screenshot", outputs.qmp_socket, outputs.screenshot)?
        screenshot_taken = true
      }

      let _ = process.kill(launched.pid, signal: "TERM")
      if profile.proof.screenshot_required and ! fs.exists(outputs.screenshot)? {
        return Err(types.LaputaError.Profile(f"QMP did not create ${outputs.screenshot}"))
      }

      print "laputa test qemu-dwl-foot: ok"
      return
    }

    if elapsed >= 180 {
      let _ = process.kill(launched.pid, signal: "TERM")
      return Err(types.LaputaError.Profile(f"timed out waiting for qemu-dwl-foot proof; inspect ${outputs.console_log}"))
    }

    time.sleep(1s)?
    elapsed += 1
  }

  return Err(types.LaputaError.Profile(f"QEMU exited before qemu-dwl-foot proof; inspect ${outputs.qemu_log}"))
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
