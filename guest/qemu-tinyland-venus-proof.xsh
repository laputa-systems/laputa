#!/bin/xsh
##! In-guest tinyland and Play proof for qemu-tinyland-venus.
##! seatd mediates as root; the compositor and Play run unprivileged as laputa.
##! Play renders on Mesa's Venus Vulkan driver over virtio-gpu; the host GPU
##! executes the work. The proof needs no Ghostty, virgl or lavapipe.
error GuestProofError = Failed(phase: Str, message: Str)

proc guest_console(message: Str) [fs, error] {
  p"/dev/console".write(
    f"""{message}
""",
  )
}

proc guest_tick(label: Str) {
  if let Ok(text) = p"/proc/uptime".read_text() {
    guest_console(f"LAPUTA_TINYLAND_T {label} uptime={text.trim()}")
  } else {
    guest_console(f"LAPUTA_TINYLAND_T {label} uptime=unknown")
  }
}

proc guest_fail(phase: Str, message: Str) {
  for log in [p"/var/log/tinyland/current", p"/var/log/seatd/current"] {
    if log.exists() { guest_console(log.read_text()?) }
  }
  guest_console(f"LAPUTA_TINYLAND_VENUS_PROOF_FAILED {phase}: {message}")
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

proc guest_process_alive(pid: Int) -> Result[Bool, Error] {
  for entry in process.list()? {
    return true when entry.pid == pid
  }

  false
}

proc guest_wait_unit(name: Str, previous: Int, ready: Bool) -> Result[Int, Error] {
  let path_value = fp"/run/xinit/{name}.json"
  var elapsed = 0
  while elapsed < 60 {
    if path_value.exists() {
      if let Ok(status) = json.read(path_value) {
        let pid = json.get(status, ["pid"], 0).require(Int)?
        let state = json.get(status, ["state"], "").require(Str)?
        let is_ready = json.get(status, ["ready"], false).require(Bool)?
        return pid when state == "running" and (! ready or is_ready) and pid != previous
      }
    }
    time.sleep(1s)
    elapsed += 1
  }
  guest_fail(name, "service did not become ready")
  Err(GuestProofError.Failed(phase: name, message: "service did not become ready"))
}

proc guest_wait_session(runtime: Path, previous: Int) -> Result[Int, Error] {
  let path_value = fp"{runtime}/laputa-tinyland.pid"
  var elapsed = 0
  while elapsed < 90 {
    if path_value.exists() and fp"{runtime}/laputa-direct-denied".exists() and fp"{runtime}/laputa-play-ready".exists() {
      if let Ok(pid_text) = path_value.read_text() {
        if let Ok(pid) = pid_text.trim().parse_int() {
          let session_id = fp"{runtime}/laputa-session-id"
          let ready_id = fp"{runtime}/laputa-play-ready"
          if session_id.exists() and pid != previous and guest_process_alive(pid) {
            if let Ok(expected) = session_id.read_text() {
              if let Ok(observed) = ready_id.read_text() {
                return pid when expected != "" and expected == observed
              }
            }
          }
        }
      }
    }
    time.sleep(1s)
    elapsed += 1
  }
  for log in [p"/var/log/tinyland/current", p"/var/log/seatd/current", fp"{runtime}/laputa-play-session.log"] {
    if log.exists() { guest_console(log.read_text()?) }
  }
  guest_fail("session", "session did not become ready")
  Err(GuestProofError.Failed(phase: "session", message: "session did not become ready"))
}

proc guest_require_broker_census(mdevd_pid: Int, seatd_pid: Int) {
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
  guest_console(f"LAPUTA_TINYLAND_BROKER_CENSUS mdevd={mdevd_pid} seatd={seatd_pid}")
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

proc guest_rss_kb(pid: Int) -> Result[Int, Error] {
  let status = fp"/proc/{pid}/status".read_text()?
  for line in status.split("\n") {
    return line.split(":")[1].trim().split(" ")[0] as Int when line.starts_with("VmRSS:")
  }
  0
}

proc guest_granted_device_control(runtime: Path) {
  let device = p"/dev/dri/card0"
  let original = fs.stat(device, follow_symlinks: false)?.mode % 4096
  let marker = fp"{runtime}/laputa-direct-opened"
  marker.remove()
  defer device.chmod(original)
  device.chmod(0o666)
  let result = process.run(process.command_argv(
    p"/usr/bin/su",
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-session.xsh"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
    timeout: 10s,
  ))
  device.chmod(original)
  let status = result?
  guard ! status.ok else { fail "device denial probe accepted granted DRM access" }
  guard marker.read_text()? == device.display() else { fail "granted DRM access did not reach the denial probe" }
  marker.remove()
  guest_console("LAPUTA_TINYLAND_GRANTED_DEVICE_REJECTED")
}

proc main() [fs, process, time, error] {
  guest_tick("start")
  let mdevd_pid = guest_wait_unit("mdevd", -1, true)?
  let _ = guest_wait_unit("coldplug", -1, true)?
  let seatd_pid = guest_wait_unit("seatd", -1, true)?
  guest_require_broker_census(mdevd_pid, seatd_pid)
  guest_console("LAPUTA_TINYLAND_COLDPLUG_COMPLETE")

  guest_wait_for(p"/dev/dri/card0", "drm-device", 20)
  var render_nodes = 0
  for node in g"/dev/dri/renderD*" {
    render_nodes += 1
    guest_console(f"LAPUTA_TINYLAND_NODE {node} mode={node.metadata()?.mode % 4096}")
  }
  guard render_nodes >= 2 else { fail f"expected a render node per virtio GPU, found {render_nodes}" }

  for device in [p"/dev/input/event0", p"/dev/input/event1"] {
    guest_wait_for(device, "input-devices", 20)
  }

  for node in [p"/dev/ptmx", p"/dev/console"] {
    if let Ok(meta) = node.metadata() {
      guest_console(f"LAPUTA_TINYLAND_NODE {node} mode={meta.mode % 4096}")
    } else {
      guest_fail("device-nodes", f"missing {node}")
    }
  }
  if let Ok(meta) = p"/run/seatd.sock".metadata() {
    guest_console(f"LAPUTA_TINYLAND_NODE /run/seatd.sock mode={meta.mode % 4096}")

    if meta.mode % 4096 != 0o770 {
      guest_fail("seatd-socket", f"unexpected seatd socket mode {meta.mode % 4096}")
    }
  } else {
    guest_fail("seatd-socket", "missing seatd socket")
  }

  let account = user.lookup("laputa")?
  let runtime = fp"/run/user/{account.uid}"
  guest_run_required(process.command_argv(
    p"/usr/bin/su",
    ["su", "nobody", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-runtime-attack.xsh"],
    stdout: p"/dev/console", stderr: p"/dev/console",
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
    timeout: 10s,
  ), "runtime-attack")
  guest_granted_device_control(runtime)
  p"/run/tinyland-proof-prepared".write("ready\n")
  let tinyland_pid = guest_wait_session(runtime, 0)?
  guest_tick("session-ready")

  let session_log = fp"{runtime}/laputa-play-session.log".read_text()?
  for line in session_log.split("\n") {
    if "Vulkan device" in line or "libvulkan_" in line or "Registered output" in line {
      guest_console(f"LAPUTA_TINYLAND_SESSION_PLAY {line.trim()}")
    }
  }
  guard "libvulkan_virtio.so" in session_log else { fail "the session Play did not load the Venus driver" }
  guard "libvulkan_lvp" not in session_log else { fail "the session Play loaded lavapipe" }
  guard "Virtio-GPU Venus" in session_log else { fail "the session Play device is not a Venus device" }
  guest_console("LAPUTA_TINYLAND_VENUS_SESSION")

  guest_tick("play-fixture-start")
  guest_run_required(process.command_argv(
    p"/usr/bin/su",
    ["su", "laputa", "-s", "/usr/bin/xsh", "/usr/lib/laputa/tinyland-play-proof.xsh"],
    stdout: p"/dev/console", stderr: p"/dev/console",
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
    timeout: 120s,
  ), "play-venus")
  guest_tick("play-text-end")
  guest_console("LAPUTA_TINYLAND_PLAY_VENUS_OK")

  guard guest_process_alive(tinyland_pid) else { fail "the compositor did not survive the Play proof" }
  guard fp"{runtime}/laputa-play-ready".exists() else { fail "the session Play did not survive the Play proof" }
  let players = [entry.pid for entry in process.list()? if entry.command == "player"]
  guard players.len() == 1 else { fail f"expected one session player after the proof, found {players.len()}" }
  guest_console(f"LAPUTA_TINYLAND_RSS tinyland_kb={guest_rss_kb(tinyland_pid)?} player_kb={guest_rss_kb(players[0])?}")

  guest_console(f"LAPUTA_TINYLAND_SESSION_PLAY_LOG {fp"{runtime}/laputa-play-session.log".read_text()?}")
  guest_console("LAPUTA_TINYLAND_VENUS_PROOF_READY")
  time.sleep(5s)
  guest_tick("end")
  guest_console("LAPUTA_TINYLAND_VENUS_PROOF_OK")
}

main()
