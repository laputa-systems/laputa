#!/bin/xsh
## The generation overlay binds the canonical guest proof into /usr/lib/laputa.
## rc.boot mounts tmpfs on /run before executing this hook, so copy the proof
## only now; embedding it under /run in the artifact would be hidden at boot.

error ProfileBootError = Failed(message: Str)

proc profile_wait_for(path_value: Path, seconds: Int) [fs, time, error] {
  var elapsed = 0
  while ! fs.exists(path_value)? {
    if elapsed >= seconds {
      return Err(ProfileBootError.Failed(f"qemu-dwl-foot boot hook timed out waiting for ${path_value}"))
    }
    time.sleep(1s)?
    elapsed += 1
  }
}

proc profile_require(value: Bool, message: Str) [error] {
  if ! value {
    return Err(ProfileBootError.Failed(message))
  }
}

proc profile_start_interactive() [fs, process, time, error] {
  let mdevd = process.which("mdevd")?
  let coldplug = process.which("mdevd-coldplug")?
  let seatd = process.which("seatd")?
  let dwl = process.which("dwl")?
  let _mdevd = spawn process.command_argv(
    mdevd,
    ["mdevd", "-O", "4", "-f", "/etc/mdev.conf", "-C"],
    env: {PATH: "/usr/local/bin:/usr/bin:/bin"},
  )?
  run $coldplug "-O" "4" ?
  let _seatd = spawn process.command_argv(seatd, ["seatd", "-g", "seat"], env: {PATH: "/usr/local/bin:/usr/bin:/bin"})?
  profile_wait_for(p"/run/seatd.sock", 20)?
  if ! fs.exists(p"/run/user/0")? {
    fs.mkdir(p"/run/user/0")?
  }
  fs.chmod(p"/run/user/0", 0o700)?
  run $dwl "-s" "/usr/bin/foot /bin/xshi --no-config" --env "PATH=/usr/local/bin:/usr/bin:/bin" --env "XDG_RUNTIME_DIR=/run/user/0" --env "LIBSEAT_BACKEND=seatd" --env "SEATD_SOCK=/run/seatd.sock" --env "WLR_BACKENDS=drm,libinput" --env "WLR_RENDERER=pixman" ?
}

let cmdline = fs.read_text(/proc/cmdline)?
if "LAPUTA_QEMU_DWL_FOOT_PROOF=1" in cmdline {
  let source = p"/usr/lib/laputa/qemu-dwl-foot-proof.xsh"
  let target = p"/run/qemu-dwl-foot-proof.xsh"
  profile_require(fs.exists(source)?, "qemu-dwl-foot guest proof was not staged in this generation")?
  fs.install(source, target, 0o755, parents: true, overwrite: true)?
  run $target ?
} else {
  profile_start_interactive()?
}
