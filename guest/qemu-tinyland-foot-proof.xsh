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

  guest_tick("crash-before-kill")
  guest_console(f"LAPUTA_TINYLAND_CRASH target={tinyland_pid}")
  process.kill(tinyland_pid, signal: "KILL")?
  let crash_pid = guest_wait_session(runtime, tinyland_pid)?
  if guest_process_alive(tinyland_pid)? { guest_fail("compositor-crash", "old compositor survived") }
  guest_console("LAPUTA_TINYLAND_CRASH session exited")?
  guest_tick("crash-reaped")
  guest_tick("crash-recovered")

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

  guest_tick("broker-loss-before-kill")
  process.kill(seatd_pid, signal: "KILL")?
  let restarted_seatd_pid = guest_wait_unit("seatd", seatd_pid, true)?
  guest_require_broker_census(mdevd_pid, restarted_seatd_pid)?
  let recovered_pid = guest_wait_session(runtime, crash_pid)?
  if guest_process_alive(crash_pid)? { guest_fail("broker-loss", "old session survived broker loss") }
  guest_console("LAPUTA_TINYLAND_BROKER_LOSS session exited")?
  guest_tick("broker-loss-reaped")
  guest_tick("broker-recovered")

  let applications = [entry.pid for entry in process.list()? if entry.command == "foot"]
  guard applications.len() == 1 else { fail "expected one application before exit qualification" }
  process.kill(applications[0], signal: "TERM")?
  let application_restart_pid = guest_wait_session(runtime, recovered_pid)?
  guard ! guest_process_alive(recovered_pid)? else { fail "old compositor survived application exit" }
  guest_console("LAPUTA_TINYLAND_APPLICATION_EXIT_RECOVERED")?

  let scanner = json.get(json.read(p"/run/xinit/scanner.json")?, ["pid"], 0).require(Int)?
  guard scanner > 1 else { fail "missing service scanner ownership" }
  let shutdown_applications = [entry.pid for entry in process.list()? if entry.command == "foot"]
  guard shutdown_applications.len() == 1 else { fail "expected one application before scanner shutdown" }
  process.kill(scanner, signal: "TERM")?
  let shutdown_mdevd = guest_wait_unit("mdevd", mdevd_pid, true)?
  let shutdown_seatd = guest_wait_unit("seatd", restarted_seatd_pid, true)?
  let _ = guest_wait_session(runtime, application_restart_pid)?
  for old in [scanner, mdevd_pid, restarted_seatd_pid, application_restart_pid, shutdown_applications[0]] {
    guard ! guest_process_alive(old)? else { fail f"owned process {old} survived scanner shutdown" }
  }
  guest_require_broker_census(shutdown_mdevd, shutdown_seatd)?
  guest_console("LAPUTA_TINYLAND_SCANNER_SHUTDOWN_REAPED")?

  guest_console("LAPUTA_TINYLAND_FOOT_PROOF_READY")
  guest_wait_for(fp"{runtime}/laputa-foot-input.txt", "input", 90)
  let input = fp"{runtime}/laputa-foot-input.txt".read_text()?.trim()
  if input != "laputa" {
    guest_fail("input", f"expected laputa, got {input}")
  }

  guest_console("LAPUTA_TINYLAND_FOOT_PROOF_OK")
}

main()
