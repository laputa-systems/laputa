#!/bin/xsh
##! In-guest tinyland and foot keyboard-input proof for qemu-tinyland-foot.
##! seatd mediates as root; the compositor and foot run unprivileged as laputa.
error GuestProofError = Failed(phase: Str, message: Str)

proc guest_console(message: Str) [fs, error] {
  p"/dev/console".write(
    f"""{message}
""",
  )
}

proc guest_fail(phase: Str, message: Str) {
  guest_console(f"LAPUTA_TINYLAND_FOOT_PROOF_FAILED {phase}: {message}")
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

  guest_wait_for(/dev/dri/card0, "drm-device", 20)

  for device in [/dev/input/event0, /dev/input/event1] {
    guest_wait_for(device, "input-devices", 20)
  }

  p"/dev/console".chmod(0o666)
  # devtmpfs/mdev leave /dev/ptmx root-owned without group access; the
  # unprivileged session needs it to allocate foot's pty.
  # TODO(laputa): own /dev/ptmx creation (mdev rule or baselayout) instead
  # of relaxing it in the proof guest.
  p"/dev/ptmx".chmod(0o666)
  p"/run/seatd.sock".remove()

  # The serial-only QEMU proof has no virtual terminal.  An unbound seat is
  # immediately active while still mediating the virtio DRM and input devices.
  let _seatd = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin", SEATD_VTBOUND: "0"},
  )?
  let _ = _seatd
  guest_wait_for(/run/seatd.sock, "seatd", 20)
  if ! p"/run/user".exists() {
    p"/run/user".mkdir()
  }

  p"/run/user".chmod(0o777)
  p"/run/user/1000/laputa-foot-input.txt".remove()
  p"/run/user/1000/laputa-foot-read-ready".remove()
  p"/run/user/1000/laputa-direct-denied".remove()
  guest_run_required(
    process.command_argv(
      /usr/bin/su,
      ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-runtime-setup.xsh"],
    ),
    "runtime-dir",
  )
  let session = spawn process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-session.xsh"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?

  guest_wait_for(/run/user/1000/laputa-direct-denied, "direct-deny", 30)
  guest_wait_for(/run/user/1000/laputa-foot-read-ready, "foot", 30)
  guest_console("LAPUTA_TINYLAND_FOOT_PROOF_READY")
  guest_wait_for(/run/user/1000/laputa-foot-input.txt, "input", 90)
  let input = p"/run/user/1000/laputa-foot-input.txt".read_text()?.trim()
  if input != "laputa" {
    guest_fail("input", f"expected laputa, got {input}")
  }

  guest_console("LAPUTA_TINYLAND_FOOT_PROOF_OK")
  let _ = wait session
}

main()
