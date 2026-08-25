error ProofError = Failed(kind: Str, message: Str)

proc append_line(file_path: Path, line: Str) [fs, error] {
  var existing = ""

  if fs.exists(file_path)? {
    existing = fs.read_text(file_path)?
  }

  fs.write(
    file_path,
    f"""${existing}${line}
""",
  )?
}

proc console_marker(line: Str) [fs, error] {
  fs.write(
    /dev/console,
    f"""${line}
""",
  )?
}

proc ensure(condition: Bool, kind: Str, message: Str) [error] {
  if ! condition {
    return Err(ProofError.Failed(kind, message))
  }
}

proc ensure_dir(path_value: Path, mode: Int) [fs, error] {
  if ! fs.exists(path_value)? {
    path_value.mkdir()?
  }

  fs.chmod(path_value, mode)?
}

proc settle_devices(log: Path, label: Str) [fs, process, time, error] {
  if fs.exists(/usr/bin/mdevd)? and fs.exists(/usr/bin/mdevd-coldplug)? {
    let mdevd = spawn process.command_argv(
      /usr/bin/mdevd,
      ["mdevd", "-O", "4", "-f", "/etc/mdev.conf"],
      env: {PATH: "/bin:/usr/bin"},
    )?

    defer terminate_if_live(mdevd.pid)
    time.sleep(200ms)?

    match process.run(
      process.command_argv(/usr/bin/mdevd-coldplug, ["mdevd-coldplug", "-O", "4"], env: {PATH: "/bin:/usr/bin"}),
    ) {
      Ok(_) => append_line(log, f"laputa-qemu ${label} mdevd-coldplug ok")?
      Err(_) => append_line(log, f"laputa-qemu ${label} mdevd-coldplug failed")?
    }

    time.sleep(500ms)?
    return
  }

  if fs.exists(/usr/bin/udevd)? and fs.exists(/usr/bin/udevadm)? {
    ensure_dir(/run/udev, 0o755)?
    let _ = spawn process.command_argv(/usr/bin/udevd, ["udevd", "--daemon"], env: {PATH: "/bin:/usr/bin"})?
    run /usr/bin/udevadm "trigger" "--action=add" ?
    run /usr/bin/udevadm "settle" "--timeout=10" ?
    append_line(log, f"laputa-qemu ${label} udev-settle ok")?
    time.sleep(500ms)?
  }
}

proc settle_sound_devices(log: Path) [fs, process, time, error] {
  settle_devices(log, "audio")?
}

proc terminate_if_live(pid: Int) [process] {
  match process.kill(pid, signal: "TERM") {
    Ok(_) => {}
    Err(_) => {}
  }
}

proc wait_for_path(path_value: Path, kind: Str, message: Str) [fs, time, error] {
  var tries = 50

  while tries > 0 {
    if fs.exists(path_value)? {
      return
    }

    time.sleep(100ms)?
    tries -= 1
  }

  return Err(ProofError.Failed(kind, message))
}

proc wait_for_path_slow(path_value: Path, kind: Str, message: Str) [fs, time, error] {
  var tries = 200

  while tries > 0 {
    if fs.exists(path_value)? {
      return
    }

    time.sleep(100ms)?
    tries -= 1
  }

  return Err(ProofError.Failed(kind, message))
}

proc wait_for_text(path_value: Path, needle: Str, kind: Str, message: Str) [fs, time, error] -> Result[Str] {
  var tries = 650

  while tries > 0 {
    if fs.exists(path_value)? {
      let body = fs.read_text(path_value)?

      if needle in body {
        return body
      }
    }

    time.sleep(100ms)?
    tries -= 1
  }

  return Err(ProofError.Failed(kind, message))
}

proc wait_for_socket(path_value: Path) [fs, time, error] {
  var tries = 50

  while tries > 0 {
    if fs.exists(path_value)? {
      let mode_class = path_value.metadata()?.mode / 4096 % 16

      if mode_class == 12 {
        return
      }
    }

    time.sleep(100ms)?
    tries -= 1
  }

  return Err(ProofError.Failed("laputa-qemu-seatd", f"seatd did not create ${path_value.display()}"))
}

proc qemu_foot_input_proof_enabled() [env] -> Bool {
  let value = (env.get("XSH_QEMU_INPUT_PROOF") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc qemu_debug_enabled() [env] -> Bool {
  let value = (env.get("XSH_QEMU_DEBUG") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc qemu_foot_shell_enabled() [env] -> Bool {
  let value = (env.get("XSH_QEMU_FOOT_SHELL") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc qemu_audio_proof_enabled() [env] -> Bool {
  let value = (env.get("XSH_QEMU_AUDIO_PROOF") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc qemu_mesa_proof_enabled() [env] -> Bool {
  let value = (env.get("XSH_QEMU_MESA_PROOF") ?? "0").trim()
  return value == "1" or value == "true" or value == "yes" or value == "on"
}

proc write_foot_input_script(script: Path) [fs, error] {
  fs.write(
    script,
    """#!/bin/xsh
proc main() [fs, io, time, error] {
  fs.write(/run/laputa-foot-input-started.txt, "started")?
  print "LAPUTA STAGE11 FOOT INPUT PROOF"
  print "type laputa and send EOF"
  let data = io.stdin_text()?
  fs.write(/run/laputa-foot-input.txt, data)?
  time.sleep(2s)?
}

main()
""",
  )?

  fs.chmod(script, 0o755)?
}

proc write_foot_visual_script(script: Path) [fs, error] {
  fs.write(
    script,
    """#!/bin/xsh
proc main() [time, error] {
  var row = 0

  while row < 50 {
    print "LAPUTA STAGE11 PIXMAN DRM DUMB FRAMEBUFFER PROOF"
    row += 1
  }

  time.sleep(20s)?
}

main(@args)?
""",
  )?

  fs.chmod(script, 0o755)?
}

proc append_command_output(log: Path, label: Str, command: Path, args: List[Str]) [fs, process, error] {
  match run.text $command @args {
    Ok(out) => append_line(log, f"laputa-qemu-debug ${label}: ${out.trim()}")?
    Err(err) => append_line(log, f"laputa-qemu-debug ${label}: failed: ${err.message}")?
  }
}

proc append_path_text(log: Path, label: Str, path_value: Path) [fs, error] {
  if fs.exists(path_value)? {
    append_line(log, f"laputa-qemu-debug ${label}: ${fs.read_text(path_value)?.trim()}")?
  } else {
    append_line(log, f"laputa-qemu-debug ${label}: missing")?
  }
}

proc dump_debug_state(log: Path) [fs, process, error] {
  append_command_output(log, "dev-dri", /bin/ls, ["-l", "/dev/dri"])?
  append_command_output(log, "dev-input", /bin/ls, ["-l", "/dev/input"])?
  append_command_output(log, "drm-sysfs", /bin/ls, ["-l", "/sys/class/drm"])?
  append_path_text(log, "card0-virtual-status", /sys/class/drm/card0-Virtual-1/status)?
  append_path_text(log, "card0-virtual-modes", /sys/class/drm/card0-Virtual-1/modes)?
  append_path_text(log, "card0-virtual-enabled", /sys/class/drm/card0-Virtual-1/enabled)?
  append_path_text(log, "card0-virtual-dpms", /sys/class/drm/card0-Virtual-1/dpms)?
}

proc verify_libinput_devices(log: Path) [fs, process, time, error] {
  settle_devices(log, "input")?
  wait_for_path(/dev/input, "laputa-qemu-input", "missing /dev/input after device settle")?
  var event_count = 0

  for entry in fs.ls(/dev/input)? {
    if entry.name.starts_with("event") {
      event_count += 1
    }
  }

  ensure(event_count >= 2, "laputa-qemu-input", f"expected at least two evdev nodes, saw ${event_count}")?
  var devices = ""
  var tries = 20

  while tries > 0 {
    devices = run.text /usr/bin/libinput "list-devices" ?
    let has_keyboard = "Keyboard" in devices or "keyboard" in devices
    let has_pointing = "Mouse" in devices or "mouse" in devices or "Pointer" in devices or "pointer" in devices or "Touchscreen" in devices or "touchscreen" in devices or "Tablet" in devices or "tablet" in devices
    break when has_keyboard and has_pointing
    time.sleep(250ms)?
    tries -= 1
  }

  ensure("Device:" in devices, "laputa-qemu-libinput", "libinput listed no devices")?

  ensure(
    "Keyboard" in devices or "keyboard" in devices,
    "laputa-qemu-libinput",
    f"libinput did not list a keyboard: ${devices.trim()}",
  )?

  ensure(
    "Mouse" in devices or "mouse" in devices or "Pointer" in devices or "pointer" in devices or "Touchscreen" in devices or "touchscreen" in devices or "Tablet" in devices or "tablet" in devices,
    "laputa-qemu-libinput",
    f"libinput did not list a pointer: ${devices.trim()}",
  )?

  append_line(log, f"laputa-qemu libinput devices=${event_count}")?
}

proc run_dwl_debug(log: Path) [fs, process, time, error] {
  let seatd_socket = /run/seatd.sock
  fs.remove(seatd_socket, missing_ok: true)?

  let seatd = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat", "-l", "info"],
    env: {SEATD_VTBOUND: "0"},
  )?

  defer terminate_if_live(seatd.pid)
  wait_for_socket(seatd_socket)?
  let runtime_dir = /run/laputa-qemu-runtime
  ensure_dir(runtime_dir, 0o700)?
  let foot_visual_script = /run/laputa-foot-visual.xsh
  write_foot_visual_script(foot_visual_script)?
  dump_debug_state(log)?
  append_line(log, "laputa-qemu-debug launch-dwl-foot-visual")?

  let command = process.command_argv(
    /usr/bin/dwl,
    ["dwl", "-s", "/usr/bin/foot /bin/xsh /run/laputa-foot-visual.xsh"],
    env: {
      LIBSEAT_BACKEND: "seatd",
      PATH: "/bin:/usr/bin",
      SEATD_SOCK: seatd_socket.display(),
      WLR_BACKENDS: "drm,libinput",
      WLR_DRM_NO_ATOMIC: "1",
      WLR_RENDERER: "pixman",
      WLR_LIBINPUT_NO_DEVICES: "0",
      WLR_SCENE_DISABLE_DIRECT_SCANOUT: "1",
      WLR_SCENE_DISABLE_VISIBILITY: "1",
      XDG_RUNTIME_DIR: runtime_dir.display(),
    },
    timeout: 18s,
  )

  let compositor = spawn command?
  defer terminate_if_live(compositor.pid)
  time.sleep(8s)?
  console_marker("laputa-qemu debug done")?
  time.sleep(8s)?
  append_line(log, "laputa-qemu-debug dwl-live-window-ok")?
}

proc run_dwl_foot_shell(log: Path) [fs, process, time, error] {
  let seatd_socket = /run/seatd.sock
  fs.remove(seatd_socket, missing_ok: true)?

  let seatd = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat", "-l", "info"],
    env: {SEATD_VTBOUND: "0"},
  )?

  defer terminate_if_live(seatd.pid)
  wait_for_socket(seatd_socket)?
  let runtime_dir = /run/laputa-qemu-runtime
  ensure_dir(runtime_dir, 0o700)?
  dump_debug_state(log)?
  append_line(log, "laputa-qemu launch-dwl-foot-shell")?

  let command = process.command_argv(
    /usr/bin/dwl,
    ["dwl", "-s", "/usr/bin/foot /bin/xshi --no-config"],
    env: {
      LIBSEAT_BACKEND: "seatd",
      PATH: "/bin:/usr/bin",
      SEATD_SOCK: seatd_socket.display(),
      WLR_BACKENDS: "drm,libinput",
      WLR_DRM_NO_ATOMIC: "1",
      WLR_RENDERER: "pixman",
      WLR_LIBINPUT_NO_DEVICES: "0",
      WLR_SCENE_DISABLE_DIRECT_SCANOUT: "1",
      WLR_SCENE_DISABLE_VISIBILITY: "1",
      XDG_RUNTIME_DIR: runtime_dir.display(),
    },
  )

  let compositor = spawn command?
  console_marker("laputa-qemu foot-shell-ready")?
  let status = wait compositor?
  ensure(status.ok, "laputa-qemu-dwl", "dwl foot shell exited non-zero")?
}

proc verify_alsa_virtio_device(log: Path) [fs, process, time, error] {
  ensure(fs.exists(/usr/bin/aplay)?, "laputa-qemu-audio", "missing aplay")?
  console_marker("laputa-qemu audio probe start")?
  settle_sound_devices(log)?
  var cards = ""
  var devices = ""
  var tries = 80

  while tries > 0 {
    if fs.exists(/proc/asound/cards)? {
      cards = fs.read_text(/proc/asound/cards)?

      match run.capture --text /usr/bin/aplay "-l" {
        Ok(out) => devices = f"${out.stdout}${out.stderr}"
        Err(_) => {}
      }

      if ("VirtIO" in cards or "virtio" in cards or "VIRTIO" in cards) and "card " in devices {
        append_line(log, f"laputa-qemu audio cards: ${cards.trim()}")?
        append_line(log, f"laputa-qemu audio devices: ${devices.trim()}")?
        console_marker("laputa-qemu audio ok")?
        return
      }
    }

    time.sleep(250ms)?
    tries -= 1
  }

  console_marker(f"laputa-qemu audio failed cards=${cards.trim()} aplay=${devices.trim()}")?

  return Err(
    ProofError.Failed("laputa-qemu-audio", f"no virtio ALSA device; cards=${cards.trim()} aplay=${devices.trim()}"),
  )
}

proc verify_mesa_runtime(log: Path) [fs, error] {
  for lib in [/usr/lib/libEGL.so.1, /usr/lib/libGLESv2.so.2, /usr/lib/libgbm.so.1] {
    ensure(fs.exists(lib)?, "laputa-qemu-mesa", f"missing ${lib.display()}")?
  }

  ensure(! fs.exists(/usr/lib/libGLX.so.0)?, "laputa-qemu-mesa", "libGLX must not be installed")?
  ensure(! fs.exists(/usr/lib/libvulkan.so.1)?, "laputa-qemu-mesa", "libvulkan must not be installed")?
  ensure(fs.exists(/usr/lib/libva.so.2)?, "laputa-qemu-mesa", "libva must be installed for VA-API runtime support")?
  append_line(log, "laputa-qemu mesa runtime ok")?
}

proc run_dwl_mesa_proof(log: Path) [fs, process, time, error] {
  verify_mesa_runtime(log)?
  let seatd_socket = /run/seatd.sock
  fs.remove(seatd_socket, missing_ok: true)?

  let seatd = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat", "-l", "info"],
    env: {SEATD_VTBOUND: "0"},
  )?

  defer terminate_if_live(seatd.pid)
  wait_for_socket(seatd_socket)?
  let runtime_dir = /run/laputa-qemu-runtime
  ensure_dir(runtime_dir, 0o700)?
  let foot_visual_script = /run/laputa-foot-visual.xsh
  write_foot_visual_script(foot_visual_script)?
  dump_debug_state(log)?
  append_line(log, "laputa-qemu launch-dwl-foot-mesa")?

  let command = process.command_argv(
    /usr/bin/dwl,
    ["dwl", "-s", "/usr/bin/foot /bin/xsh /run/laputa-foot-visual.xsh"],
    env: {
      GALLIUM_DRIVER: "softpipe",
      LIBGL_ALWAYS_SOFTWARE: "1",
      LIBSEAT_BACKEND: "seatd",
      MESA_LOADER_DRIVER_OVERRIDE: "kms_swrast",
      PATH: "/bin:/usr/bin",
      SEATD_SOCK: seatd_socket.display(),
      WLR_BACKENDS: "drm,libinput",
      WLR_DRM_NO_ATOMIC: "1",
      WLR_LIBINPUT_NO_DEVICES: "0",
      WLR_RENDERER: "gles2",
      WLR_RENDERER_ALLOW_SOFTWARE: "1",
      WLR_SCENE_DISABLE_DIRECT_SCANOUT: "1",
      WLR_SCENE_DISABLE_VISIBILITY: "1",
      XDG_RUNTIME_DIR: runtime_dir.display(),
    },
    timeout: 18s,
  )

  let compositor = spawn command?
  defer terminate_if_live(compositor.pid)
  time.sleep(14s)?
  append_line(log, "laputa-qemu mesa dwl-live-window-ok")?
  console_marker("laputa-qemu mesa ok")?
  time.sleep(8s)?
}

proc verify_dwl_start(log: Path) [fs, process, env, time, error] {
  if ! fs.exists(/usr/bin/dwl)? {
    return
  }

  let seatd_socket = /run/seatd.sock
  fs.remove(seatd_socket, missing_ok: true)?

  let seatd = spawn process.command_argv(
    /usr/bin/seatd,
    ["seatd", "-g", "seat", "-l", "silent"],
    env: {SEATD_VTBOUND: "0"},
  )?

  defer terminate_if_live(seatd.pid)
  wait_for_socket(seatd_socket)?
  let runtime_dir = /run/laputa-qemu-runtime
  ensure_dir(runtime_dir, 0o700)?
  let input_proof = qemu_foot_input_proof_enabled()
  let foot_input_script = /run/laputa-foot-input.xsh
  let foot_input = /run/laputa-foot-input.txt
  let foot_input_started = /run/laputa-foot-input-started.txt
  var argv = ["dwl"]

  if fs.exists(/usr/bin/foot)? {
    if input_proof {
      fs.remove(foot_input, missing_ok: true)?
      fs.remove(foot_input_started, missing_ok: true)?
      write_foot_input_script(foot_input_script)?
      argv = ["dwl", "-s", "/usr/bin/foot /bin/xsh /run/laputa-foot-input.xsh"]
      append_line(log, "laputa-qemu dwl-start foot-input-proof=enabled")?
    } else {
      argv = ["dwl", "-s", "/usr/bin/foot /usr/bin/true"]
      append_line(log, "laputa-qemu dwl-start foot-startup=enabled")?
    }
  }

  let startup_timeout = if input_proof { 60s } else { 3s }

  let command = process.command_argv(
    /usr/bin/dwl,
    argv,
    env: {
      LIBSEAT_BACKEND: "seatd",
      PATH: "/bin:/usr/bin",
      SEATD_SOCK: seatd_socket.display(),
      WLR_BACKENDS: "drm,libinput",
      WLR_DRM_NO_ATOMIC: "1",
      WLR_RENDERER: "pixman",
      WLR_LIBINPUT_NO_DEVICES: "0",
      WLR_SCENE_DISABLE_DIRECT_SCANOUT: "1",
      WLR_SCENE_DISABLE_VISIBILITY: "1",
      XDG_RUNTIME_DIR: runtime_dir.display(),
    },
    timeout: startup_timeout,
  )

  let compositor = spawn command?

  if input_proof {
    wait_for_path_slow(foot_input_started, "laputa-qemu-foot-input", "foot input recorder did not start")?
    console_marker("laputa-qemu foot-input-ready")?
    let typed = wait_for_text(foot_input, "laputa", "laputa-qemu-foot-input", "foot did not receive sentinel input")?
    append_line(log, f"laputa-qemu foot-input text=${typed.trim()}")?
    append_line(log, "laputa-qemu foot-input ok")?
    console_marker("laputa-qemu foot-input ok")?
    terminate_if_live(compositor.pid)
    return
  }

  match wait compositor {
    Err(ProcessError.Timeout {message: _}) => append_line(log, "laputa-qemu dwl-start timeout-ok")?
    Err(e) => return Err(ProofError.Failed("laputa-qemu-dwl", f"dwl wait failed: ${e.message}"))
    Ok(status) => {
      ensure(status.ok, "laputa-qemu-dwl", "dwl exited before the startup window elapsed")?
      append_line(log, "laputa-qemu dwl-start exited-ok")?
    }
  }
}

proc verify_qemu(log: Path) [fs, process, env, time, error] {
  let enabled = env.get("XSH_QEMU_PROOF") ?? "0"

  if enabled.trim() != "1" {
    return
  }

  if qemu_audio_proof_enabled() {
    verify_alsa_virtio_device(log)?

    if ! qemu_mesa_proof_enabled() and ! qemu_foot_shell_enabled() and ! qemu_debug_enabled() {
      return
    }
  }

  verify_libinput_devices(log)?

  if qemu_mesa_proof_enabled() {
    run_dwl_mesa_proof(log)?
  }

  if qemu_foot_shell_enabled() {
    run_dwl_foot_shell(log)?
    return
  }

  if qemu_debug_enabled() {
    run_dwl_debug(log)?
    append_line(log, "laputa-qemu debug ok")?
    return
  }

  verify_dwl_start(log)?
  append_line(log, "laputa-qemu ok")?
}

proc main(root: Path = /) [fs, process, env, time, error] {
  let run_dir = fp"${root}/run/xinit"
  fs.mkdir(run_dir)?
  let proof_log = fp"${run_dir}/proof.log"
  let proof_done = fp"${run_dir}/proof.done"
  fs.remove(proof_log, missing_ok: true)?
  fs.remove(proof_done, missing_ok: true)?

  fs.write(
    proof_done,
    """done
""",
  )?

  verify_qemu(proof_log)?
  print true
}

match main(@args) {
  Ok(_) => {}
  Err(err) => {
    match fs.write(
      /dev/console,
      f"""laputa-qemu proof failed: ${err.message}
""",
    ) {
      Ok(_) => {}
      Err(_) => {}
    }

    match fs.write(
      /dev/kmsg,
      f"""laputa-qemu proof failed: ${err.message}
""",
    ) {
      Ok(_) => {}
      Err(_) => {}
    }

    Err(err)?
  }
}
