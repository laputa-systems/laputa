#!/bin/xsh
##! Canonical in-guest dwl and foot keyboard-input proof for qemu-dwl-foot.
error GuestProofError = Failed(phase: Str, message: Str)

proc guest_console(message: Str) [fs, error] {
  p"/dev/console".write(
    f"""{message}
""",
  )
}

proc guest_fail(phase: Str, message: Str) {
  guest_console(f"LAPUTA_DWL_FOOT_PROOF_FAILED {phase}: {message}")
  return Err(GuestProofError.Failed(phase:, message:))
}

proc guest_wait_for(path_value: Path, phase: Str, seconds: Int) {
  var elapsed = 0
  while ! path_value.exists() {
    if elapsed >= seconds {
      guest_fail(phase, f"missing {path_value}")
    }

    time.sleep(1s)
    elapsed += 1
  }
}

proc guest_run_required(command: Command, phase: Str) {
  if let Ok(status) = process.run(command) {
    if ! status.ok {
      guest_fail(phase, "command exited unsuccessfully")
    }
  } else {
    guest_fail(phase, "command could not start")
  }
}

proc main() [fs, process, time, error] {
  let _mdevd = spawn process.command_argv(
    /usr/bin/mdevd,
    ["mdevd", "-O", "4", "-f", "/etc/mdev.conf", "-C"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?
  let _ = _mdevd
  guest_run_required(process.command_argv(/usr/bin/mdevd-coldplug, ["mdevd-coldplug", "-O", "4"]), "coldplug")

  for device in [/dev/input/event0, /dev/input/event1] {
    guest_wait_for(device, "input-devices", 20)
  }

  p"/run/seatd.sock".remove(missing_ok: true)

  # The serial-only QEMU proof has no virtual terminal.  An unbound seat is
  # immediately active while still mediating the virtio DRM and input devices.
  let _seatd = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin", SEATD_VTBOUND: "0"},
  )?
  let _ = _seatd
  guest_wait_for(/run/seatd.sock, "seatd", 20)
  if ! p"/run/user/0".exists() {
    p"/run/user/0".mkdir()
  }

  p"/run/user/0".chmod(0o700)
  p"/run/laputa-foot-input.txt".remove(missing_ok: true)
  p"/run/laputa-foot-read-ready".remove(missing_ok: true)
  p"/run/laputa-foot-read.xsh".write(
    """#!/bin/xsh
fs.write(p"/run/laputa-foot-read-ready", "ready\\n")?
print "LAPUTA_DWL_FOOT_VISUAL"
let input = io.stdin_text()?
fs.write(p"/run/laputa-foot-input.txt", input)?
""", mode: 0o755,
  )
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
  guest_wait_for(/run/laputa-foot-read-ready, "foot", 30)
  guest_console("LAPUTA_DWL_FOOT_PROOF_READY")
  guest_wait_for(/run/laputa-foot-input.txt, "input", 90)
  let input = p"/run/laputa-foot-input.txt".read_text()?.trim()
  if input != "laputa" {
    guest_fail("input", f"expected laputa, got {input}")
  }

  guest_console("LAPUTA_DWL_FOOT_PROOF_OK")
}

main()
