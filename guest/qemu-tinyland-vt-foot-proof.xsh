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

proc guest_process_alive(pid: Int) [process, error] -> Result[Bool, Error] {
  for entry in process.list()? {
    if entry.pid == pid { return true }
  }
  false
}

proc guest_wait_unit(name: Str, previous: Int, ready: Bool) [fs, time, error] -> Result[Int, Error] {
  let path_value = fp"/run/xinit/{name}.json"
  var elapsed = 0
  while elapsed < 60 {
    if path_value.exists() {
      if let Ok(status) = json.read(path_value) {
        let pid = json.get(status, ["pid"], 0).require(Int)?
        let state = json.get(status, ["state"], "").require(Str)?
        let is_ready = json.get(status, ["ready"], false).require(Bool)?
        if state == "running" and (! ready or is_ready) and pid != previous {
          return pid
        }
      }
    }
    time.sleep(1s)
    elapsed += 1
  }
  guest_fail(name, "service did not become ready")
  return Err(GuestProofError.Failed(phase: name, message: "service did not become ready"))
}

proc guest_wait_session(runtime: Path, previous: Int) [fs, process, time, error] -> Result[Int, Error] {
  let path_value = fp"{runtime}/laputa-tinyland.pid"
  var elapsed = 0
  while elapsed < 60 {
    if path_value.exists() and fp"{runtime}/laputa-direct-denied".exists() and fp"{runtime}/laputa-foot-read-ready".exists() {
      if let Ok(pid_text) = path_value.read_text() {
        if let Ok(pid) = pid_text.trim().parse_int() {
          let session_id = fp"{runtime}/laputa-session-id"
          let ready_id = fp"{runtime}/laputa-foot-read-ready"
          if session_id.exists() and pid != previous and guest_process_alive(pid)? {
            if let Ok(expected) = session_id.read_text() {
              if let Ok(observed) = ready_id.read_text() {
                if expected != "" and expected == observed { return pid }
              }
            }
          }
        }
      }
    }
    time.sleep(1s)
    elapsed += 1
  }
  guest_fail("session", "replacement session did not become ready")
  return Err(GuestProofError.Failed(phase: "session", message: "replacement session did not become ready"))
}

proc guest_require_broker_census(mdevd_pid: Int, seatd_pid: Int) [fs, process, error] {
  var mdevd_count = 0
  var seatd_count = 0
  var matching_mdevd = false
  var matching_seatd = false
  for entry in process.list()? {
    if entry.command == "mdevd" {
      mdevd_count += 1
      matching_mdevd = matching_mdevd or entry.pid == mdevd_pid
    }
    if entry.command == "seatd" {
      seatd_count += 1
      matching_seatd = matching_seatd or entry.pid == seatd_pid
    }
  }
  guard mdevd_count == 1 and matching_mdevd else { fail "mdevd census differs from scanner ownership" }
  guard seatd_count == 1 and matching_seatd else { fail "seatd census differs from scanner ownership" }
  guest_console(f"LAPUTA_TINYLAND_BROKER_CENSUS mdevd={mdevd_pid} seatd={seatd_pid}")?
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
  let mdevd_pid = guest_wait_unit("mdevd", -1, true)?
  let _ = guest_wait_unit("coldplug", -1, true)?
  let seatd_pid = guest_wait_unit("seatd", -1, true)?
  guest_require_broker_census(mdevd_pid, seatd_pid)?
  guest_console("LAPUTA_TINYLAND_COLDPLUG_COMPLETE")?
  guest_run_required(process.command_argv(/usr/bin/xsh, ["xsh", "/usr/lib/laputa/doas-qualification.xsh"], stdout: /dev/console, stderr: /dev/console), "doas-qualification")

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
  guest_run_required(process.command_argv(
    /usr/bin/su,
    ["su", "nobody", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-runtime-attack.xsh"],
    stdout: /dev/console, stderr: /dev/console,
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
    timeout: 10s,
  ), "runtime-attack")
  guest_granted_device_control(runtime)?
  p"/run/tinyland-proof-prepared".write("ready\n")?
  let tinyland_pid = guest_wait_session(runtime, 0)?
  guest_tick("session-ready")

  # Compositor crash sanity: SIGKILL tinyland mid-session; foot and the
  # reader die with it, the broker stays up, and a fresh session recovers
  # without touching the broker.
  guest_tick("crash-before-kill")
  guest_console(f"LAPUTA_TINYLAND_CRASH target={tinyland_pid}")
  process.kill(tinyland_pid, signal: "KILL")?
  let _ = guest_wait_session(runtime, tinyland_pid)?
  if guest_process_alive(tinyland_pid)? { guest_fail("compositor-crash", "old compositor survived") }
  guest_console("LAPUTA_TINYLAND_CRASH session exited")?
  guest_tick("crash-reaped")
  guest_tick("crash-recovered")

  guest_console("LAPUTA_TINYLAND_VT_SWITCH_AWAY")
  var vt_elapsed = 0
  while ! fp"{runtime}/laputa-seat-disabled".exists() {
    if vt_elapsed >= 30 {
      guest_fail("vt-disable", "missing runtime seat-disabled marker")
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

  guest_console("LAPUTA_TINYLAND_VT_SWITCH_BACK")
  var vt_back_elapsed = 0
  while ! fp"{runtime}/laputa-seat-enabled".exists() {
    if vt_back_elapsed >= 30 {
      guest_fail("vt-resume", "missing runtime seat-enabled marker")
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
  guest_wait_for(fp"{runtime}/laputa-foot-input.txt", "input", 90)
  let input = fp"{runtime}/laputa-foot-input.txt".read_text()?.trim()
  if input != "laputa" {
    guest_fail("input", f"expected laputa, got {input}")
  }

  guest_console("LAPUTA_TINYLAND_VT_FOOT_PROOF_OK")
}

main()
