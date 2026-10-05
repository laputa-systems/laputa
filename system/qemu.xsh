##! Structured QEMU construction and supervision for qemu-dwl-foot.
use system.build
use system.image
use system.proof
use system.types

## The host half of a QEMU invocation, which the profile does not choose: the
## guest machine with its hardware accelerator and board options, the CPU
## model, the serial console arguments, the root disk transport, and the
## interactive display.
export type QemuTarget = {
  arch: Str,
  qemu_name: Str,
  machine: Str,
  machine_args: List[Str],
  cpu: Str,
  console: Str,
  block_device: Str,
  interactive_display: List[Str],
}

## The host executable, QMP helper, and host target used by a QEMU invocation.
export type QemuConfig = {qemu: Path, python: Path, qmp_helper: Path, target: QemuTarget}

# aarch64 virt has a PL011 UART and virtio-mmio block devices; x86_64 q35 has a
# 16550 UART and virtio-pci, and a default VGA adapter that `-vga none`
# removes: the virtio GPU must be the only display, or QEMU's screendump
# captures the VGA text console instead of the compositor. Linux hosts take
# QEMU's default interactive display.
## The QEMU target for a host: the guest is the host's architecture, so the
## image runs under HVF on macOS and KVM on Linux.
export pure qemu_target(os: Str, arch: Str) -> Result[QemuTarget, Error] {
  let arm_console = "earlycon=pl011,mmio,0x09000000 keep_bootcon console=ttyAMA0"

  if os == "Darwin" and arch == "aarch64" {
    return {
      arch,
      qemu_name: "qemu-system-aarch64",
      machine: "virt,accel=hvf,highmem=off",
      machine_args: [],
      cpu: "host",
      console: arm_console,
      block_device: "virtio-blk-device",
      interactive_display: ["-display", "cocoa,zoom-to-fit=on,show-cursor=on"],
    }
  }

  if os == "Linux" and arch == "aarch64" {
    return {
      arch,
      qemu_name: "qemu-system-aarch64",
      machine: "virt,accel=kvm",
      machine_args: [],
      cpu: "host",
      console: arm_console,
      block_device: "virtio-blk-device",
      interactive_display: [],
    }
  }

  if os == "Linux" and arch == "x86_64" {
    return {
      arch,
      qemu_name: "qemu-system-x86_64",
      machine: "q35,accel=kvm",
      machine_args: ["-vga", "none"],
      cpu: "host",
      console: "earlyprintk=serial console=ttyS0",
      block_device: "virtio-blk-pci",
      interactive_display: [],
    }
  }

  Err(types.LaputaError.Profile(f"no QEMU target for {os} {arch}; qemu-dwl-foot runs natively on macOS aarch64 or Linux aarch64/x86_64"))
}

## The running host's QEMU target.
export proc host_qemu_target() [env, error] -> Result[QemuTarget, Error] {
  let os = system.uname()?
  let arch = match os.machine {
    "arm64" | "aarch64" => "aarch64"
    "amd64" | "x86_64" => "x86_64"
    other => other
  }

  qemu_target(os.sysname, arch)?
}

## Return the stable root PARTUUID written by Laputa's GPT image module.
export pure root_partuuid() -> Str {
  image.image_root_partuuid()
}

## Build the serial-console kernel command line for a host target and profile mode.
export pure kernel_cmdline(target: QemuTarget, mode: types.QemuMode) -> Str {
  let base = f"{target.console} ignore_loglevel devtmpfs.mount=1 root=PARTUUID={root_partuuid()} rootfstype=ext4 rootwait rootdelay=2 rw init=/init loglevel=8 XSH_LINUX_REAL=1 XSH_UNIX_REAL=1"

  return f"{base} LAPUTA_QEMU_DWL_FOOT_PROOF=1" when mode == types.Test

  base
}

## Resolve only the documented host-side QEMU configuration surface.
export proc qemu_config(laputa_root: Path, target: QemuTarget) [fs, process, env, error] -> Result[QemuConfig, Error] {
  # QEMU_SYSTEM_AARCH64 or QEMU_SYSTEM_X86_64 names a specific binary.
  let raw_qemu = (env.get(f"QEMU_SYSTEM_{target.arch.upper()}") ?? "").trim()
  let qemu = if raw_qemu == "" { process.which(target.qemu_name)? } else { fp"{raw_qemu}" }
  let python = process.which("python3")?
  let qmp_helper = fp"{laputa_root}/boot/qmp-proof.py"

  if ! fs.exists(qmp_helper)? {
    return Err(types.LaputaError.Profile(f"missing QMP helper {qmp_helper}"))
  }

  {qemu, python, qmp_helper, target}
}

## Construct an exact QEMU argv without a shell command boundary.
export pure qemu_command_argv(
  value: QemuConfig,
  profile: types.SystemProfile,
  outputs: build.ProfileOutputs,
  mode: types.QemuMode,
) -> List[Str] {
  let target = value.target
  let display = if mode == types.Test { ["-display", "none"] } else { target.interactive_display }

  [
    value.qemu.display(),
    "-M",
    target.machine,
    @target.machine_args,
    "-cpu",
    target.cpu,
    "-smp",
    f"{profile.qemu_smp}",
    "-m",
    profile.qemu_memory,
    "-kernel",
    outputs.kernel.display(),
    "-append",
    kernel_cmdline(target, mode),
    "-drive",
    f"if=none,id=root,format=raw,file={outputs.disk},snapshot=on",
    "-device",
    f"{target.block_device},drive=root",
    "-netdev",
    "user,id=net0",
    "-device",
    "virtio-net-pci,netdev=net0",
    "-device",
    f"virtio-gpu-pci,xres={profile.qemu_width},yres={profile.qemu_height}",
    "-device",
    "virtio-keyboard-pci",
    "-device",
    "virtio-tablet-pci",
    "-device",
    "virtio-mouse-pci",
    "-qmp",
    f"unix:{outputs.qmp_socket},server,nowait",
    @display,
    "-serial",
    "stdio",
    "-no-reboot",
  ]
}

# QEMU's managed handle owns the process group; cancel sends TERM, waits five
# seconds, then escalates that group to KILL and reaps it.  Do not replace this
# with a background shell watcher: it would lose the explicit cleanup boundary.
proc qemu_stop(launched: ProcessHandle) [process, error] {
  launched.cancel(signal: "TERM", kill_after: 5s)
}

# Returns whether the spawned QEMU group leader is still running, without a
# shell watcher. An exited QEMU stays a zombie (status `Z`) until it is
# reaped, and signal 0 still reaches a zombie, so the process table decides.
proc qemu_process_live(pid: Int) -> Result[Bool] {
  for entry in process.list()? |> where .pid == pid {
    return entry.status != "Z"
  }

  false
}

# Invokes the retained focused Python QMP helper with structured arguments.
proc qemu_qmp(value: QemuConfig, mode: Str, socket: Path, screenshot: Path = p"") {
  var argv = [value.python.display(), value.qmp_helper.display(), mode, socket.display()]
  if screenshot != "" {
    argv += [screenshot.display()]
  }

  let status = process.run(process.command_argv(value.python, argv))?
  return Err(types.LaputaError.Docker(f"QMP {mode} helper failed")) unless status.ok
}

# Retry idempotent QMP readiness or screenshot requests while QEMU publishes
# its socket.  Keyboard input is deliberately *not* retried: a late transport
# error could otherwise duplicate the proof keystrokes.
proc qemu_qmp_retry(value: QemuConfig, mode: Str, socket: Path, screenshot: Path = p"") {
  var attempt = 0
  while attempt < 20 {
    match qemu_qmp(value, mode, socket, screenshot) {
      Ok(_) => return
      Err(_) => {
        time.sleep(250ms)
        attempt += 1
      }
    }
  }

  return Err(types.LaputaError.Docker(f"QMP {mode} helper did not become ready"))
}

## Combine QEMU's serial console and stderr log before scanning proof markers:
## fatal QEMU diagnostics can be emitted on stderr rather than serial.
export proc qemu_log_text(console_log: Path, qemu_log: Path) [fs, error] -> Result[Str, Error] {
  let console = if fs.exists(console_log)? { fs.read_text(console_log)? } else { "" }
  let qemu = if fs.exists(qemu_log)? { fs.read_text(qemu_log)? } else { "" }
  f"""{console}
{qemu}"""
}

## A screenshot is proof evidence only when QMP wrote nonempty image bytes.
export proc screenshot_is_valid(path_value: Path) [fs, error] -> Result[Bool, Error] {
  fs.exists(path_value)? and fs.metadata(path_value)?.kind == "file" and fs.metadata(path_value)?.size > 0
}

pure qemu_output_locations(outputs: build.ProfileOutputs) -> Str {
  f"console={outputs.console_log}; qemu-log={outputs.qemu_log}; screenshot={outputs.screenshot}"
}

## Run a bounded headless proof, inject input through QMP, and validate its output.
export proc run_test(
  value: QemuConfig,
  profile: types.SystemProfile,
  outputs: build.ProfileOutputs,
) [fs, process, time, error] {
  if ! fs.exists(outputs.kernel)? or ! fs.exists(outputs.disk)? {
    return Err(types.LaputaError.Profile("qemu-dwl-foot image is missing; run laputa build first"))
  }

  fs.remove(outputs.console_log, missing_ok: true)
  fs.remove(outputs.qemu_log, missing_ok: true)
  fs.remove(outputs.qmp_socket, missing_ok: true)
  fs.remove(outputs.screenshot, missing_ok: true)
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
    let failed = proof.failure_marker(log_text)
    if failed != "" {
      qemu_stop(launched)
      return Err(
        types.LaputaError.Profile(f"QEMU proof failed with {failed}; inspect {qemu_output_locations(outputs)}"),
      )
    }

    # READY is printed by the guest only after dwl has launched foot's reader.
    # This keeps exactly one deterministic `laputa` plus EOF QMP injection.
    if ! injected and fs.exists(outputs.qmp_socket)? and "LAPUTA_DWL_FOOT_PROOF_READY" in log_text {
      qemu_qmp_retry(value, "ready", outputs.qmp_socket)
      qemu_qmp(value, "input", outputs.qmp_socket)
      injected = true
    }

    if proof.succeeded(log_text) {
      if ! screenshot_taken {
        qemu_qmp_retry(value, "screenshot", outputs.qmp_socket, outputs.screenshot)
        screenshot_taken = true
      }

      qemu_stop(launched)
      let final_log = qemu_log_text(outputs.console_log, outputs.qemu_log)?
      proof.verify_console(final_log)
      if ! screenshot_is_valid(outputs.screenshot)? {
        return Err(
          types.LaputaError.Profile(f"QMP did not create a nonempty screenshot; inspect {qemu_output_locations(outputs)}"),
        )
      }

      print "laputa test qemu-dwl-foot: ok"
      return
    }

    if elapsed >= 180 {
      qemu_stop(launched)
      return Err(
        types.LaputaError.Profile(f"timed out waiting for qemu-dwl-foot proof; inspect {qemu_output_locations(outputs)}"),
      )
    }

    time.sleep(1s)
    elapsed += 1
  }

  let _ = wait launched?
  let final_log = qemu_log_text(outputs.console_log, outputs.qemu_log)?
  match proof.verify_console(final_log) {
    Ok(_) => return Err(
      types.LaputaError.Profile(
        f"QEMU exited after guest proof before supervisor completion; inspect {qemu_output_locations(outputs)}",
      ),
    )
    Err(_) => return Err(
      types.LaputaError.Profile(f"QEMU exited before qemu-dwl-foot proof; inspect {qemu_output_locations(outputs)}"),
    )
  }
}

## Run the profile's normal interactive session and return its real QEMU exit status.
export proc boot(value: QemuConfig, profile: types.SystemProfile, outputs: build.ProfileOutputs) [fs, process, error] {
  if ! fs.exists(outputs.kernel)? or ! fs.exists(outputs.disk)? {
    return Err(types.LaputaError.Profile("qemu-dwl-foot image is missing; run laputa build first"))
  }

  let status = process.run(
    process.command_argv(value.qemu, qemu_command_argv(value, profile, outputs, types.Interactive)),
  )?
  if ! status.ok {
    return Err(types.LaputaError.Docker("interactive QEMU exited unsuccessfully"))
  }
}
