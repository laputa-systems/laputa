##! Structured QEMU construction and supervision for the QEMU profiles.
use system.build
use system.image
use system.launcher
use system.proof
use system.qmp
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

## The host transport for a QMP connection.
export enum QemuQmpTransport { QemuQmpLinux, QemuQmpLegacy(Path, Path) }
## The host executable, QMP transport, and host target used by a QEMU invocation.
export type QemuConfig = {qemu: Path, qmp_transport: QemuQmpTransport, target: QemuTarget}

enum QmpOperation { QmpReady, QmpInput, QmpVtSwitch(Int), QmpScreenshot(Path) }
enum QmpRetryOperation { QmpRetryReady, QmpRetryScreenshot(Path) }
error QmpFailure = OutcomeIndeterminate(operation: QmpOperation)

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

  Err(
    types.LaputaError.Profile(
      f"no QEMU target for {os} {arch}; profiles run natively on macOS aarch64 or Linux aarch64/x86_64",
    ),
  )
}

## The running host's QEMU target.
export proc host_qemu_target() [env, error] -> Result[QemuTarget, Error] {
  let os = system.uname()?
  let arch = match os.machine {
    "arm64" | "aarch64" => "aarch64",
    "amd64" | "x86_64" => "x86_64",
    other => other,
  }

  qemu_target(os.sysname, arch)?
}

## Return the stable root PARTUUID written by Laputa's GPT image module.
export pure root_partuuid() -> Str {
  image.image_root_partuuid()
}

## Build the serial-console kernel command line for a host target and profile mode.
export pure kernel_cmdline(target: QemuTarget, mode: types.QemuMode, proof: types.ProofMarkers) -> Str {
  let base = f"{target.console} ignore_loglevel devtmpfs.mount=1 root=PARTUUID={root_partuuid()} rootfstype=ext4 rootwait rootdelay=2 rw init=/init loglevel=8 XSH_LINUX_REAL=1 XSH_UNIX_REAL=1"

  return f"{base} {proof.cmdline_flag}=1" when mode == .Test

  base
}

## Resolve only the documented host-side QEMU configuration surface.
export proc qemu_config(laputa_root: Path, target: QemuTarget) [fs, process, env, error] -> Result[QemuConfig, Error] {
  let raw_qemu = (env.get(f"QEMU_SYSTEM_{target.arch.upper()}") ?? "").trim()
  let qemu = if raw_qemu == "" { process.which(target.qemu_name)? } else { fp"{raw_qemu}" }
  let qmp_transport = if system.uname()?.sysname == "Linux" {
    QemuQmpLinux
  } else {
    let python = process.which("python3")?
    let helper = fp"{laputa_root}/boot/qmp-proof.py"
    if ! helper.exists() {
      return Err(types.LaputaError.Profile(f"missing QMP helper {helper}"))
    }
    QemuQmpLegacy(python, helper)
  }
  {qemu, qmp_transport, target}
}

## Construct an exact QEMU argv without a shell command boundary.
export pure qemu_command_argv(
  value: QemuConfig,
  profile: types.SystemProfile,
  outputs: build.ProfileOutputs,
  mode: types.QemuMode,
) -> List[Str] {
  let target = value.target
  let display = if mode == .Test { ["-display", "none"] } else { target.interactive_display }
  let state_drive = if profile.development { [] } else {
    ["-drive", f"if=none,id=state,format=raw,file={outputs.root}/state.ext4", "-device", f"{target.block_device},drive=state"]
  }

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
    kernel_cmdline(target, mode, profile.proof),
    "-drive",
    f"if=none,id=root,format=raw,file={outputs.disk},snapshot=on",
    "-device",
    f"{target.block_device},drive=root",
    @state_drive,
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

## Attach the declared read-only inputs and writable output disk to a self-hosting guest.
export pure qemu_self_hosting_disks_argv(target: QemuTarget, inputs: Path, output: Path) -> List[Str] {
  [
    "-drive", f"if=none,id=inputs,format=raw,file={inputs},readonly=on",
    "-device", f"{target.block_device},drive=inputs",
    "-drive", f"if=none,id=output,format=raw,file={output}",
    "-device", f"{target.block_device},drive=output",
  ]
}

proc qemu_stop(launched: ProcessHandle) [process, error] {
  launched.cancel(signal: "TERM", kill_after: 5s)
}

proc qemu_process_live(pid: Int) -> Result[Bool] {
  for entry in process.list()? |> where .pid == pid {
    return entry.status != "Z"
  }

  false
}

pure qmp_mode(operation: QmpOperation) -> Str {
  match operation {
    QmpReady => "ready"
    QmpInput => "input"
    QmpVtSwitch(_) => "vt-switch"
    QmpScreenshot(_) => "screenshot"
  }
}

pure qmp_retry_operation(operation: QmpRetryOperation) -> QmpOperation {
  match operation {
    QmpRetryReady => QmpReady
    QmpRetryScreenshot(output) => QmpScreenshot(output)
  }
}

type QemuQmpKey = {type: Str, data: Str}
type QemuQmpKeyData = {key: QemuQmpKey, down: Bool}
type QemuQmpKeyEvent = {type: Str, data: QemuQmpKeyData}

proc qmp_key_step(keys: List[Str], down: Bool) -> Result[qmp.QmpStep, Error] {
  let events: List[QemuQmpKeyEvent] = [
    {type: "key", data: {key: {type: "qcode", data: key}, down}}
    for key in keys
  ]
  qmp.QmpExecute("input-send-event", json.encode({events})?, qmp.QmpMutation)
}

proc qmp_linux_steps(operation: QmpOperation) -> Result[List[qmp.QmpStep], Error] {
  match operation {
    QmpReady => Ok([]),
    QmpScreenshot(output) => Ok([qmp.QmpExecute("screendump", json.encode({filename: output.display()})?, qmp.QmpReadOnly)]),
    QmpVtSwitch(vt) => Ok([
      qmp_key_step(["ctrl", "alt", f"f{vt}"], true)?,
      qmp.QmpDelay(500),
      qmp_key_step([f"f{vt}", "alt", "ctrl"], false)?,
    ]),
    QmpInput => {
      var steps: List[qmp.QmpStep] = []
      for key in ["l", "a", "p", "u", "t", "a", "ret"] {
        steps += [qmp_key_step([key], true)?, qmp.QmpDelay(40), qmp_key_step([key], false)?, qmp.QmpDelay(40)]
      }
      for pair in [{key: "ctrl", down: true}, {key: "d", down: true}, {key: "d", down: false}, {key: "ctrl", down: false}] {
        steps += [qmp_key_step([pair.key], pair.down)?]
      }
      Ok(steps)
    },
  }
}

proc qemu_qmp(value: QemuConfig, operation: QmpOperation, socket: Path) {
  match value.qmp_transport {
    QemuQmpLinux => {
      match qmp.qmp_linux_run(socket, qmp_linux_steps(operation)?, 60000) {
        Ok(_) => Ok(),
        Err(qmp.QmpError.Indeterminate {operation: _}) => Err(QmpFailure.OutcomeIndeterminate(operation)),
        Err(problem) => Err(problem),
      }
    },
    QemuQmpLegacy(python, helper) => {
      var argv = [python.display(), helper.display(), qmp_mode(operation), socket.display()]
      if let QmpScreenshot(output) = operation { argv += [output.display()] }
      if let QmpVtSwitch(vt) = operation { argv += [f"{vt}"] }
      let status = process.run(process.command_argv(python, argv))?
      return Err(QmpFailure.OutcomeIndeterminate(operation)) when status.exited_with(75)
      return Err(types.LaputaError.Docker(f"QMP {qmp_mode(operation)} helper failed")) unless status.ok
      Ok()
    },
  }
}

## Pause or resume a disposable guest without retrying an unknown outcome.
export enum QemuControl { QemuStop, QemuContinue }

## Send a single pause or resume command over the configured host transport.
export proc qemu_control(value: QemuConfig, socket: Path, control: QemuControl) -> Result[Unit, Error] {
  let command = match control { QemuStop => "stop", QemuContinue => "cont" }
  match value.qmp_transport {
    QemuQmpLinux => qmp.qmp_linux_run(socket, [qmp.QmpExecute(command, "{}", qmp.QmpMutation)], 5000),
    QemuQmpLegacy(python, helper) => {
      let status = process.run(process.command_argv(python, [python.display(), helper.display(), command, socket.display()], timeout: 5s))?
      if !status.ok { return Err(types.LaputaError.Docker(f"QMP {command} helper failed")) }
      Ok()
    },
  }
}

proc qemu_qmp_retry(value: QemuConfig, operation: QmpRetryOperation, socket: Path) {
  let qmp_operation = qmp_retry_operation(operation)
  var attempt = 0
  while attempt < 20 {
    match qemu_qmp(value, qmp_operation, socket) {
      Ok(_) => return
      Err(QmpFailure.OutcomeIndeterminate {operation: detail}) => return Err(QmpFailure.OutcomeIndeterminate(detail))
      Err(_) => {
        time.sleep(250ms)
        attempt += 1
      }
    }
  }

  return Err(types.LaputaError.Docker(f"QMP {qmp_mode(qmp_operation)} helper did not become ready"))
}

## Combine QEMU's serial console and stderr log before scanning proof markers:
## fatal QEMU diagnostics can be emitted on stderr rather than serial.
export proc qemu_log_text(console_log: Path, qemu_log: Path) [fs, error] -> Result[Str, Error] {
  let console = if console_log.exists() { console_log.read_text()? } else { "" }
  let qemu = if qemu_log.exists() { qemu_log.read_text()? } else { "" }
  f"""{console}
{qemu}"""
}

## A screenshot is proof evidence only when QMP wrote nonempty image bytes.
export proc screenshot_is_valid(path_value: Path) [fs, error] -> Result[Bool, Error] {
  path_value.exists()? and path_value.is_file()? and path_value.metadata()?.size > 0
}

pure ppm_data_offset(image: Bytes) -> Int {
  return -1 unless image.starts_with(b"P6\n")

  var line_feeds = 0
  var index = 0
  while index < image.len() {
    if (image.byte_at(index) ?? -1) == 10 {
      line_feeds += 1
      if line_feeds == 3 {
        return index + 1 when image.slice(0, index + 1).ends_with(b"255\n")
        return -1
      }
    }

    index += 1
  }

  -1
}

pure ppm_has_foot_marker(image: Bytes) -> Bool {
  let pixel_offset = ppm_data_offset(image)
  return false when pixel_offset < 0

  var marker_pixels = 0
  var index = pixel_offset
  while index + 2 < image.len() {
    let red = image.byte_at(index) ?? -1
    let green = image.byte_at(index + 1) ?? -1
    let blue = image.byte_at(index + 2) ?? -1
    if red == 255 and green == 0 and blue == 255 {
      marker_pixels += 1
      return true when marker_pixels >= 16
    } else {
      marker_pixels = 0
    }

    index += 3
  }

  false
}

proc screenshot_has_foot_marker(path_value: Path) -> Result[Bool, Error] {
  ppm_has_foot_marker(path_value.read_bytes()?)
}

pure qemu_output_locations(outputs: build.ProfileOutputs) -> Str {
  f"console={outputs.console_log}; qemu-log={outputs.qemu_log}; screenshot={outputs.screenshot}"
}

## Run a bounded headless proof, inject input through QMP, and validate its output.
export proc run_test(
  value: QemuConfig,
  profile: types.SystemProfile,
  outputs: build.ProfileOutputs,
) [fs, process, net, time, error] {
  if ! outputs.kernel.exists() or ! outputs.disk.exists() {
    return Err(types.LaputaError.Profile(f"{profile.name} image is missing; run laputa build first"))
  }

  outputs.console_log.remove()
  outputs.qemu_log.remove()
  outputs.qmp_socket.remove()
  outputs.screenshot.remove()
  let command = process.command_argv(
    value.qemu,
    qemu_command_argv(value, profile, outputs, types.Test),
    stdout: outputs.console_log,
    stderr: outputs.qemu_log,
  )
  let launched = spawn command?
  defer qemu_stop(launched)
  var elapsed = 0
  var injected = false
  var vt_away = false
  var vt_back = false
  var screenshot_taken = false

  while qemu_process_live(launched.pid) {
    let log_text = qemu_log_text(outputs.console_log, outputs.qemu_log)?
    let failed = proof.failure_marker(profile.proof, log_text)
    if failed != "" {
      return Err(
        types.LaputaError.Profile(f"QEMU proof failed with {failed}; inspect {qemu_output_locations(outputs)}"),
      )
    }

    if !vt_away and profile.proof.vt_away_marker != "" and outputs.qmp_socket.exists() and profile.proof.vt_away_marker in log_text {
      qemu_qmp(value, QmpVtSwitch(2), outputs.qmp_socket)
      vt_away = true
    }

    if !vt_back and profile.proof.vt_back_marker != "" and outputs.qmp_socket.exists() and profile.proof.vt_back_marker in log_text {
      qemu_qmp(value, QmpVtSwitch(1), outputs.qmp_socket)
      vt_back = true
    }

    if ! injected and outputs.qmp_socket.exists() and profile.proof.ready_marker in log_text {
      qemu_qmp_retry(value, QmpRetryReady, outputs.qmp_socket)
      qemu_qmp(value, QmpInput, outputs.qmp_socket)
      injected = true
    }

    if proof.succeeded(profile.proof, log_text) {
      if ! screenshot_taken {
        qemu_qmp_retry(value, QmpRetryScreenshot(outputs.screenshot), outputs.qmp_socket)
        if ! screenshot_is_valid(outputs.screenshot) {
          return Err(
            types.LaputaError.Profile(f"QMP did not create a nonempty screenshot; inspect {qemu_output_locations(outputs)}"),
          )
        }
        if ! screenshot_has_foot_marker(outputs.screenshot) {
          return Err(
            types.LaputaError.Profile(
              f"QMP screenshot does not contain the foot visual marker; inspect {qemu_output_locations(outputs)}",
            ),
          )
        }

        screenshot_taken = true
      }

      qemu_stop(launched)
      let final_log = qemu_log_text(outputs.console_log, outputs.qemu_log)?
      proof.verify_console(profile.proof, final_log)

      print f"laputa test {profile.name}: ok"
      return
    }

    if elapsed >= 180 {
      return Err(
        types.LaputaError.Profile(f"timed out waiting for {profile.name} proof; inspect {qemu_output_locations(outputs)}"),
      )
    }

    time.sleep(1s)
    elapsed += 1
  }

  let _ = wait launched?
  let final_log = qemu_log_text(outputs.console_log, outputs.qemu_log)?
  match proof.verify_console(profile.proof, final_log) {
    Ok(_) => return Err(
      types.LaputaError.Profile(
        f"QEMU exited after guest proof before supervisor completion; inspect {qemu_output_locations(outputs)}",
      ),
    )
    Err(_) => return Err(
      types.LaputaError.Profile(f"QEMU exited before {profile.name} proof; inspect {qemu_output_locations(outputs)}"),
    )
  }
}

## QEMU argv for one boot. A profile generations directory selects that record's kernel and disk.
export proc boot_command_argv(
  value: QemuConfig,
  profile: types.SystemProfile,
  outputs: build.ProfileOutputs,
  mode: types.QemuMode,
  generations: Path? = null,
) [fs, time, error] -> Result[List[Str], Error] {
  if ! profile.development {
    let state_image = fp"{outputs.root}/state.ext4"
    guard state_image.exists() and state_image.is_file() else {
      fail "maintained state image is missing"
    }
    guard state_image.metadata()?.mode.bit_and(0o077) == 0 else {
      fail "maintained state image must be private"
    }
  }
  let argv = qemu_command_argv(value, profile, outputs, mode)

  if generations == null {
    argv
  } else {
    let image = launcher.launcher_select(generations)?
    var selected = launcher.launcher_qemu_argv(argv, image)?
    for index in range(selected.len() - 1) {
      if selected[index] == "-append" {
        selected[index + 1] += f" LAPUTA_GENERATION_ID={image.id} LAPUTA_BOOT_SERIAL={image.boot_serial}"
      }
    }
    selected
  }
}

## Run the profile's normal interactive session and return its real QEMU exit status.
export proc boot(value: QemuConfig, profile: types.SystemProfile, outputs: build.ProfileOutputs) [fs, process, time, error] {
  let generations = launcher.launcher_state(outputs.root)?

  if generations == null and (! outputs.kernel.exists() or ! outputs.disk.exists()) {
    return Err(types.LaputaError.Profile(f"{profile.name} image is missing; run laputa build first"))
  }

  let argv = boot_command_argv(value, profile, outputs, types.Interactive, generations)?
  let status = process.run(process.command_argv(value.qemu, argv))?
  if ! status.ok {
    return Err(types.LaputaError.Docker("interactive QEMU exited unsuccessfully"))
  }
}
