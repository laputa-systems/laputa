#!/bin/xsh
##! Canonical in-guest dwl and foot keyboard-input proof for qemu-dwl-foot.
error GuestProofError = Failed(phase: Str, message: Str)

proc guest_console(message: Str) [fs, error] {
  fs.write(/dev/console, f"${message}\n")?
}

proc guest_fail(phase: Str, message: Str) [fs, error] {
  guest_console(f"LAPUTA_DWL_FOOT_PROOF_FAILED ${phase}: ${message}")?
  return Err(GuestProofError.Failed(phase, message))
}

proc guest_wait_for(path_value: Path, phase: Str, seconds: Int) [fs, time, error] {
  var elapsed = 0
  while ! fs.exists(path_value)? {
    if elapsed >= seconds {
      guest_fail(phase, f"missing ${path_value}")?
    }
    time.sleep(1s)?
    elapsed += 1
  }
}

proc guest_run_required(command: Command, phase: Str) [fs, process, error] {
  match process.run(command) {
    Ok(status) => {
      if ! status.ok {
        guest_fail(phase, "command exited unsuccessfully")?
      }
    }
    Err(_) => guest_fail(phase, "command could not start")?
  }
}

proc main() [fs, process, time, error] {
  let _mdevd = spawn process.command_argv(
    /usr/bin/mdevd,
    ["mdevd", "-O", "4", "-f", "/etc/mdev.conf", "-C"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?
  guest_run_required(process.command_argv(/usr/bin/mdevd-coldplug, ["mdevd-coldplug", "-O", "4"]), "coldplug")?

  for device in [p"/dev/input/event0", p"/dev/input/event1"] {
    guest_wait_for(device, "input-devices", 20)?
  }

  fs.remove(p"/run/seatd.sock", missing_ok: true)?
  # The serial-only QEMU proof has no virtual terminal.  An unbound seat is
  # immediately active while still mediating the virtio DRM and input devices.
  let _seatd = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin", SEATD_VTBOUND: "0"},
  )?
  guest_wait_for(p"/run/seatd.sock", "seatd", 20)?
  if ! fs.exists(p"/run/user/0")? {
    fs.mkdir(p"/run/user/0")?
  }
  fs.chmod(p"/run/user/0", 0o700)?
  fs.remove(p"/run/laputa-foot-input.txt", missing_ok: true)?
  fs.remove(p"/run/laputa-foot-read-ready", missing_ok: true)?
  fs.write(
    p"/run/laputa-foot-read.xsh",
    """#!/bin/xsh
fs.write(p"/run/laputa-foot-read-ready", "ready\\n")?
print "LAPUTA_DWL_FOOT_VISUAL"
let input = io.stdin_text()?
fs.write(p"/run/laputa-foot-input.txt", input)?
""",
  )?
  fs.chmod(p"/run/laputa-foot-read.xsh", 0o755)?
  let command = process.command_argv(
    /usr/bin/dwl,
    ["dwl", "-s", "/usr/bin/foot -- /bin/xsh /run/laputa-foot-read.xsh"],
    env: {
      PATH: "/usr/local/bin:/usr/bin:/bin",
      XDG_RUNTIME_DIR: "/run/user/0",
      LIBSEAT_BACKEND: "seatd",
      SEATD_SOCK: "/run/seatd.sock",
      WLR_BACKENDS: "drm,libinput",
      WLR_RENDERER: "pixman",
    },
  )
  let compositor = spawn command?
  let _ = compositor
  # This appears only after dwl has started foot and foot has started its
  # stdin reader.  The host sends QMP keyboard input only after this boundary.
  guest_wait_for(p"/run/laputa-foot-read-ready", "foot", 30)?
  guest_console("LAPUTA_DWL_FOOT_PROOF_READY")?
  guest_wait_for(p"/run/laputa-foot-input.txt", "input", 90)?
  let input = fs.read_text(p"/run/laputa-foot-input.txt")?.trim()
  if input != "laputa" {
    guest_fail("input", f"expected laputa, got ${input}")?
  }
  guest_console("LAPUTA_DWL_FOOT_PROOF_OK")?
}

main()?
