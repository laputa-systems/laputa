#!/bin/xsh
##! In-guest tinyland and foot keyboard-input proof for qemu-tinyland-foot.
##! seatd mediates as root; the compositor and foot run unprivileged as laputa.
##! Before readiness the proof kills the compositor mid-session and recovers
##! behind the same markers. Broker loss stays out of the guest until the
##! pinned tinyland reports daemon death (see R3).
error GuestProofError = Failed(phase: Str, message: Str)

proc guest_console(message: Str) [fs, error] {
  p"/dev/console".write(
    f"""{message}
""",
  )
}

# Phase timing for lifecycle recovery claims: boot-relative seconds from the
# guest clock, logged raw and parsed on the host.
proc guest_tick(label: Str) [fs, error] {
  match p"/proc/uptime".read_text() {
    Ok(text) => guest_console(f"LAPUTA_TINYLAND_T {label} uptime={text.trim()}")
    Err(_) => guest_console(f"LAPUTA_TINYLAND_T {label} uptime=unknown")
  }
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
  guest_tick("start")
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

  # Device nodes are owned by mdev rules (see baselayout mdev.conf); log the
  # effective modes before the unprivileged session needs them. The mdevd
  # catch-all would set root:root 0660 here, which the session cannot use.
  for node in [/dev/ptmx, /dev/console] {
    match node.metadata() {
      Ok(meta) => {
        guest_console(f"LAPUTA_TINYLAND_NODE {node.display()} mode={meta.mode % 4096}")
      },
      Err(_) => {
        guest_fail("device-nodes", f"missing {node.display()}")
      },
    }
  }
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

  # The broker socket must stay group-mediated: laputa reaches it through
  # the seat group, never through a world-accessible or root-only socket.
  match p"/run/seatd.sock".metadata() {
    Ok(meta) => {
      guest_console(f"LAPUTA_TINYLAND_NODE /run/seatd.sock mode={meta.mode % 4096}")

      if meta.mode % 4096 != 0o770 {
        guest_fail("seatd-socket", f"unexpected seatd socket mode {meta.mode % 4096}")
      }
    },
    Err(_) => {
      guest_fail("seatd-socket", "missing seatd socket")
    },
  }
  if ! p"/run/user".exists() {
    p"/run/user".mkdir()
  }

  p"/run/user".chmod(0o777)
  p"/run/user/1000/laputa-foot-input.txt".remove()
  p"/run/user/1000/laputa-foot-read-ready".remove()
  p"/run/user/1000/laputa-direct-denied".remove()
  p"/run/user/1000/laputa-tinyland.pid".remove()
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
  guest_tick("session-ready")

  # R3: compositor crash. SIGKILL tinyland mid-session: foot and the reader
  # die with it, the broker stays up, and a fresh session recovers without
  # touching the broker.
  guest_wait_for(/run/user/1000/laputa-tinyland.pid, "tinyland-pid", 30)
  guest_tick("crash-before-kill")
  let tinyland_pid = p"/run/user/1000/laputa-tinyland.pid".read_text()?.trim().parse_int()?
  guest_console(f"LAPUTA_TINYLAND_CRASH target={tinyland_pid}")
  process.kill(tinyland_pid, signal: "KILL")?
  match wait session {
    Ok(status) => match status.exit_code() {
      Ok(code) => guest_console(f"LAPUTA_TINYLAND_CRASH session exited code={code}")
      Err(_) => guest_console("LAPUTA_TINYLAND_CRASH session exited unknown")
    },
    Err(_) => {
      guest_fail("compositor-crash", "session wait failed")
    },
  }
  guest_tick("crash-reaped")
  p"/run/user/1000/laputa-foot-read-ready".remove()
  p"/run/user/1000/laputa-direct-denied".remove()
  p"/run/user/1000/laputa-tinyland.pid".remove()
  let session_crash = spawn process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-session.xsh"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?
  guest_wait_for(/run/user/1000/laputa-tinyland.pid, "tinyland-pid-crash-restart", 30)
  guest_wait_for(/run/user/1000/laputa-direct-denied, "direct-deny-crash-restart", 30)
  guest_wait_for(/run/user/1000/laputa-foot-read-ready, "foot-crash-restart", 30)
  guest_tick("crash-recovered")

  guest_console("LAPUTA_TINYLAND_FOOT_PROOF_READY")
  guest_wait_for(/run/user/1000/laputa-foot-input.txt, "input", 90)
  let input = p"/run/user/1000/laputa-foot-input.txt".read_text()?.trim()
  if input != "laputa" {
    guest_fail("input", f"expected laputa, got {input}")
  }

  guest_console("LAPUTA_TINYLAND_FOOT_PROOF_OK")
  let _ = wait session_crash
}

main()
