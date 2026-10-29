#!/bin/xsh
##! In-guest tinyland and foot keyboard-input proof for qemu-tinyland-foot.
##! seatd mediates as root; the compositor and foot run unprivileged as laputa.
##! Before readiness the proof kills the compositor (crash reclaim) and the
##! broker (fail-closed loss) and recovers each behind the same markers.
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

proc guest_wait_for_removed(path_value: Path, phase: Str, seconds: Int) {
  var elapsed = 0
  while path_value.exists() {
    if elapsed >= seconds {
      guest_fail(phase, f"{path_value} still present")
    }

    if elapsed % 10 == 0 {
      guest_tick(f"{phase}-wait")
    }

    time.sleep(1s)
    elapsed += 1
  }
}

proc guest_find_input(name: Str, phase: Str) -> Result[Path, Error] {
  for entry in g"/dev/input/event*" {
    let candidate = fp"/sys/class/input/{entry.name}/device/name"

    if candidate.exists() and candidate.read_text()?.trim() == name {
      return entry
    }
  }

  guest_fail(phase, f"no input device named {name}")
  return Err(GuestProofError.Failed(phase:, message: f"no input device named {name}"))
}

## Resolve the PCI address behind an input event node through sysfs, so the
## guest can remove the device itself: unplug must not depend on host
## scheduling.
proc guest_pci_of_input(event_name: Str, phase: Str) -> Result[Str, Error] {
  let link = fp"/sys/class/input/{event_name}"
  let target = link.readlink()?
  let physical = if target.starts_with("/") {
    fp"{target}"
  } else {
    fp"{link.parent.display()}/{target}".normalize()
  }

  for component in physical.display().split("/") {
    if component.starts_with("0000:") {
      return component
    }
  }

  guest_fail(phase, f"no PCI parent for {event_name}")
  return Err(GuestProofError.Failed(phase:, message: f"no PCI parent for {event_name}"))
}

proc guest_process_alive(pid: Int) [process, error] -> Result[Bool, Error] {
  for entry in process.list()? {
    if entry.pid == pid {
      return true
    }
  }

  false
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

proc guest_granted_device_control(runtime: Path) [fs, process, error] {
  let device = p"/dev/dri/card0"
  let original = fs.stat(device, follow_symlinks: false)?.mode % 4096
  let marker = fp"{runtime}/laputa-direct-opened"
  marker.remove()
  defer device.chmod(original)
  device.chmod(0o666)?
  let result = process.run(process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-session.xsh"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
    timeout: 10s,
  ))
  device.chmod(original)?
  let status = result?
  guard ! status.ok else { fail "device denial probe accepted granted DRM access" }
  guard marker.read_text()? == device.display() else { fail "granted DRM access did not reach the denial probe" }
  marker.remove()?
  guest_console("LAPUTA_TINYLAND_GRANTED_DEVICE_REJECTED")?
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
  guest_run_required(process.command_argv(/usr/bin/xsh, ["xsh", "/usr/lib/laputa/doas-qualification.xsh"]), "doas-qualification")

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
  let seatd = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin", SEATD_VTBOUND: "0"},
  )?
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
  let account = user.lookup("laputa")?
  let runtime = fp"/run/user/{account.uid}"
  guest_run_required(
    process.command_argv(/usr/bin/xsh, ["xsh", "/usr/lib/laputa/tinyland-runtime-setup.xsh"]),
    "runtime-dir",
  )
  guest_run_required(process.command_argv(
    /usr/bin/su,
    ["su", "nobody", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-runtime-attack.xsh"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
    timeout: 10s,
  ), "runtime-attack")
  guest_granted_device_control(runtime)?
  fp"{runtime}/laputa-foot-input.txt".remove()
  fp"{runtime}/laputa-foot-read-ready".remove()
  fp"{runtime}/laputa-direct-denied".remove()
  fp"{runtime}/laputa-tinyland.pid".remove()
  let session = spawn process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-session.xsh"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?

  guest_wait_for(fp"{runtime}/laputa-direct-denied", "direct-deny", 30)
  guest_wait_for(fp"{runtime}/laputa-foot-read-ready", "foot", 30)
  guest_tick("session-ready")

  # R3: compositor crash. SIGKILL tinyland mid-session: foot and the reader
  # die with it, the broker stays up, and a fresh session recovers without
  # touching the broker.
  guest_wait_for(fp"{runtime}/laputa-tinyland.pid", "tinyland-pid", 30)
  guest_tick("crash-before-kill")
  let tinyland_pid = fp"{runtime}/laputa-tinyland.pid".read_text()?.trim().parse_int()?
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
  fp"{runtime}/laputa-foot-read-ready".remove()
  fp"{runtime}/laputa-direct-denied".remove()
  fp"{runtime}/laputa-tinyland.pid".remove()
  let session_crash = spawn process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-session.xsh"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?
  guest_wait_for(fp"{runtime}/laputa-tinyland.pid", "tinyland-pid-crash-restart", 30)
  guest_wait_for(fp"{runtime}/laputa-direct-denied", "direct-deny-crash-restart", 30)
  guest_wait_for(fp"{runtime}/laputa-foot-read-ready", "foot-crash-restart", 30)
  guest_tick("crash-recovered")

  # R3: supported device loss. Resolve the virtio keyboard's event node and
  # PCI address by name, remove it through sysfs, and require the session
  # to survive on the remaining AT keyboard with no stuck modifiers. The
  # guest drives removal itself so the outcome never depends on host
  # scheduling; the observed sequence matches a host unplug (REMOVE uevent,
  # ENODEV to open handles, node gone).
  let virtio_event = guest_find_input("QEMU Virtio Keyboard", "device-loss")?
  let virtio_pci = guest_pci_of_input(virtio_event.name, "device-loss")?
  guest_console(f"LAPUTA_TINYLAND_UNPLUG target={virtio_event.display()} pci={virtio_pci}")
  fp"/sys/bus/pci/devices/{virtio_pci}/remove".write("1")?
  guest_wait_for_removed(virtio_event, "device-loss", 60)
  guest_tick("unplugged")
  time.sleep(2s)

  let survivor_pid = fp"{runtime}/laputa-tinyland.pid".read_text()?.trim().parse_int()?

  if !guest_process_alive(survivor_pid)? {
    guest_fail("device-loss", "compositor died on single keyboard loss")
  }

  if ! fp"{runtime}/laputa-foot-read-ready".exists() {
    guest_fail("device-loss", "foot reader died on single keyboard loss")
  }

  # R3: broker loss must fail closed. SIGKILL seatd: the session cannot
  # reopen or fall back to direct open, so it exits; a fresh broker reclaims
  # the stale socket and a fresh session recovers. Needs a compositor that
  # reports daemon death from dispatch (tinyland e40d653).
  guest_tick("broker-loss-before-kill")
  process.kill(seatd.pid, signal: "KILL")?
  match wait session_crash {
    Ok(status) => match status.exit_code() {
      Ok(code) => guest_console(f"LAPUTA_TINYLAND_BROKER_LOSS session exited code={code}")
      Err(_) => guest_console("LAPUTA_TINYLAND_BROKER_LOSS session exited unknown")
    },
    Err(_) => {
      guest_fail("broker-loss", "session wait failed")
    },
  }
  guest_tick("broker-loss-reaped")
  let _ = wait seatd
  fp"{runtime}/laputa-foot-input.txt".remove()
  fp"{runtime}/laputa-foot-read-ready".remove()
  fp"{runtime}/laputa-direct-denied".remove()
  fp"{runtime}/laputa-tinyland.pid".remove()
  let seatd_restarted = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin", SEATD_VTBOUND: "0"},
  )?
  let _ = seatd_restarted
  guest_wait_for(/run/seatd.sock, "seatd-restart", 20)
  let session_broker = spawn process.command_argv(
    /usr/bin/su,
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-session.xsh"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?
  guest_wait_for(fp"{runtime}/laputa-tinyland.pid", "tinyland-pid-broker-restart", 30)
  guest_wait_for(fp"{runtime}/laputa-direct-denied", "direct-deny-broker-restart", 30)
  guest_wait_for(fp"{runtime}/laputa-foot-read-ready", "foot-broker-restart", 30)
  guest_tick("broker-recovered")

  guest_console("LAPUTA_TINYLAND_FOOT_PROOF_READY")
  guest_wait_for(fp"{runtime}/laputa-foot-input.txt", "input", 90)
  let input = fp"{runtime}/laputa-foot-input.txt".read_text()?.trim()
  if input != "laputa" {
    guest_fail("input", f"expected laputa, got {input}")
  }

  guest_console("LAPUTA_TINYLAND_FOOT_PROOF_OK")
  let _ = wait session_broker
}

main()
