#!/bin/xsh
## The generation overlay binds the canonical guest proof into /usr/lib/laputa.
## rc.boot mounts tmpfs on /run before executing this hook, so copy the proof
## only now; embedding it under /run in the artifact would be hidden at boot.

proc profile_wait_for(path_value: Path, seconds: Int) {
  var elapsed = 0
  while ! path_value.exists() {
    if elapsed >= seconds {
      fail f"qemu-tinyland-vt-foot boot hook timed out waiting for {path_value}"
    }
    time.sleep(1s)
    elapsed += 1
  }
}

proc profile_require(value: Bool, message: Str) [error] {
  fail message unless value
}

proc profile_start_interactive() {
  let mdevd = process.which("mdevd")?
  let coldplug = process.which("mdevd-coldplug")?
  let seatd = process.which("seatd")?
  let su = process.which("su")?
  # The creating scope owns both background children until the compositor exits.
  let _ = spawn process.command_argv(
    mdevd,
    ["mdevd", "-O", "4", "-f", "/etc/mdev.conf", "-C"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?
  run $coldplug "-O" "4"
  # This profile drives a serial-only virtio-GPU machine, so no tty0 exists to
  # activate a VT-bound seat.  Keep seatd's DRM/input mediation but make its
  # session active without a virtual terminal.
  let _ = spawn process.command_argv(
    seatd,
    ["seatd", "-g", "seat"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin", SEATD_VTBOUND: "1"},
  )?
  profile_wait_for(p"/run/seatd.sock", 20)
  # The runtime directory must belong to the session user. There is no
  # working chown in the image, so the unprivileged user creates its own
  # directory inside a world-writable /run/user prepared here.
  if ! p"/run/user".exists() {
    p"/run/user".mkdir()
  }
  p"/run/user".chmod(0o777)
  run $su "laputa" "-s" "/usr/bin/xsh" "/usr/lib/laputa/tinyland-runtime-setup.xsh"
  # The interactive session runs unprivileged; mediation comes from the broker.
  run $su "laputa" "-s" "/usr/bin/xsh" "-c" "/usr/bin/tinyland --seat -- /usr/bin/foot" --env "PATH=/usr/local/bin:/usr/bin:/bin" --env "XDG_RUNTIME_DIR=/run/user/1000" --env "LIBSEAT_BACKEND=seatd" --env "SEATD_SOCK=/run/seatd.sock"
}

let cmdline = p"/proc/cmdline".read_text()?
if "LAPUTA_QEMU_TINYLAND_VT_FOOT_PROOF=1" in cmdline {
  let source = p"/usr/lib/laputa/qemu-tinyland-vt-foot-proof.xsh"
  let target = p"/run/qemu-tinyland-vt-foot-proof.xsh"
  profile_require(source.exists()?, "qemu-tinyland-vt-foot guest proof was not staged in this generation")
  fs.install(source, target, 0o755, parents: true, overwrite: true)
  run $target
} else {
  profile_start_interactive()
}
