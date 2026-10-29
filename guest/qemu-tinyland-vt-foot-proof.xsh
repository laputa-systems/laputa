#!/bin/xsh
##! In-guest VT-bound tinyland and foot proof for qemu-tinyland-vt-foot.
##! A VT-bound seatd mediates as root; the compositor and foot run unprivileged as laputa.
##! Before readiness the proof kills the compositor (crash reclaim), switches
##! away and back across VTs (disable/resume), and recovers each behind the
##! same markers.
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
  guest_console(f"LAPUTA_TINYLAND_VT_FOOT_PROOF_FAILED {phase}: {message}")
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

  # The VT switch test needs kernel virtual terminals on the framebuffer
  # console; fail here with a named phase if the kernel left them out.
  guest_wait_for(/dev/tty0, "vt-console", 20)

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

  # VT-bound seat: the session is active while its virtual terminal is
  # foreground. The guest switches away and back to prove disable/resume.
  let _seatd = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin", SEATD_VTBOUND: "1"},
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
  p"/run/user/1000/laputa-seat-disabled".remove()
  p"/run/user/1000/laputa-seat-enabled".remove()
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

  # Compositor crash sanity: SIGKILL tinyland mid-session; foot and the
  # reader die with it, the broker stays up, and a fresh session recovers
  # without touching the broker.
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
  p"/run/user/1000/laputa-seat-disabled".remove()
  p"/run/user/1000/laputa-seat-enabled".remove()
  let session_vt = spawn process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-session.xsh"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?
  guest_wait_for(/run/user/1000/laputa-tinyland.pid, "tinyland-pid-crash-restart", 30)
  guest_wait_for(/run/user/1000/laputa-direct-denied, "direct-deny-crash-restart", 30)
  guest_wait_for(/run/user/1000/laputa-foot-read-ready, "foot-crash-restart", 30)
  guest_tick("crash-recovered")

  # R4: VT switch away. The host sends Ctrl+Alt+F2; the VT-bound seat
  # disables the session and revokes its devices. The active VT is polled
  # alongside the marker so a silent no-switch is distinguishable from a
  # switch without disable.
  guest_console("LAPUTA_TINYLAND_VT_SWITCH_AWAY")
  var vt_elapsed = 0
  while ! p"/run/user/1000/laputa-seat-disabled".exists() {
    if vt_elapsed >= 30 {
      guest_fail("vt-disable", "missing /run/user/1000/laputa-seat-disabled")
    }

    if vt_elapsed % 5 == 0 {
      match p"/sys/class/tty/tty0/active".read_text() {
        Ok(active) => guest_console(f"LAPUTA_TINYLAND_VT active={active.trim()}"),
        Err(_) => guest_console("LAPUTA_TINYLAND_VT active=unknown"),
      }
    }

    time.sleep(1s)
    vt_elapsed += 1
  }
  guest_tick("vt-disabled")

  # R4: VT switch back. The host sends Ctrl+Alt+F1; the session reopens its
  # devices and resumes with no stuck modifiers and no revoked descriptors.
  guest_console("LAPUTA_TINYLAND_VT_SWITCH_BACK")
  var vt_back_elapsed = 0
  while ! p"/run/user/1000/laputa-seat-enabled".exists() {
    if vt_back_elapsed >= 30 {
      guest_fail("vt-resume", "missing /run/user/1000/laputa-seat-enabled")
    }

    if vt_back_elapsed % 5 == 0 {
      match p"/sys/class/tty/tty0/active".read_text() {
        Ok(active) => guest_console(f"LAPUTA_TINYLAND_VT_BACK active={active.trim()}"),
        Err(_) => guest_console("LAPUTA_TINYLAND_VT_BACK active=unknown"),
      }
    }

    time.sleep(1s)
    vt_back_elapsed += 1
  }
  guest_tick("vt-resumed")

  guest_console("LAPUTA_TINYLAND_VT_FOOT_PROOF_READY")
  guest_wait_for(/run/user/1000/laputa-foot-input.txt, "input", 90)
  let input = p"/run/user/1000/laputa-foot-input.txt".read_text()?.trim()
  if input != "laputa" {
    guest_fail("input", f"expected laputa, got {input}")
  }

  guest_console("LAPUTA_TINYLAND_VT_FOOT_PROOF_OK")
  let _ = wait session_vt
}

main()
