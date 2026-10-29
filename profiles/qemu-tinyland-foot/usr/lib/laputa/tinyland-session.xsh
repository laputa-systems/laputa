#!/bin/xsh
##! Unprivileged tinyland session for the qemu-tinyland-foot proof.
##! Runs as laputa: direct device opens must fail, then the brokered
##! session carries the compositor and foot client. Readiness, input, and
##! success markers are owned by the outer guest proof and the host.
error SessionError = DeniedOpen(device: Str)

proc deny_open(path_value: Path, write: Bool, runtime: Path) [fs, process, error] {
  match unix.open_fd(path_value, write: write, nonblock: true) {
    Ok(fd) => {
      unix.close_fd(fd)?
      fp"{runtime}/laputa-direct-opened".write(path_value.display())?
      return Err(SessionError.DeniedOpen(path_value.display()))
    },
    Err(error) => {
      let code = error.errno ?? -1
      if code != 1 and code != 13 {
        return Err(error)
      }
    },
  }
}

proc main() [fs, process, env, error] {
  let account = user.lookup("laputa")?
  let runtime = fp"/run/user/{account.uid}"
  for name in ["laputa-foot-input.txt", "laputa-foot-read-ready", "laputa-direct-denied", "laputa-tinyland.pid", "laputa-seat-disabled", "laputa-seat-enabled"] {
    fp"{runtime}/{name}".remove()?
  }
  let control = unix.open_fd(p"/dev/null", nonblock: true)?
  unix.close_fd(control)?
  match deny_open(p"/dev/null", false, runtime) {
    Err(SessionError.DeniedOpen {device}) => {
      guard device == "/dev/null" else { fail "direct-open negative control returned the wrong path" }
    },
    Err(error) => { return Err(error) },
    Ok(_) => { fail "direct-open negative control unexpectedly reported denial" },
  }
  let identity = unix.id()?
  let status = p"/proc/self/status".read_text()?
  fp"{runtime}/laputa-direct-opened".remove()?
  guard identity.uid == account.uid and identity.euid == account.uid else { fail "session is not running as laputa" }
  p"/dev/console".write(f"LAPUTA_TINYLAND_ID uid={identity.uid} euid={identity.euid} gid={identity.gid} egid={identity.egid}\n")?
  var cap_eff_seen = false
  for line in status.split("\n") {
    if line.starts_with("CapEff:") {
      cap_eff_seen = true
      guard line.split(":")[1].trim() == "0000000000000000" else { fail "session has effective capabilities" }
    }
    if line.starts_with("CapEff:") or line.starts_with("Groups:") {
      p"/dev/console".write(f"LAPUTA_TINYLAND_{line}\n")?
    }
  }
  guard cap_eff_seen else { fail "session capability state missing" }
  deny_open(p"/dev/dri/card0", true, runtime)?
  deny_open(p"/dev/input/event0", false, runtime)?
  p"/dev/console".write("LAPUTA_TINYLAND_DIRECT_DENIED\n")?
  fp"{runtime}/laputa-direct-denied".write("denied\n")?
  match p"/dev/ptmx".metadata() {
    Ok(meta) => {
      p"/dev/console".write(f"LAPUTA_TINYLAND_PTMX mode={meta.mode % 4096}\n")?
    },
    Err(_) => {
      p"/dev/console".write("LAPUTA_TINYLAND_PTMX_MISSING\n")?
    },
  }
  env ({
    PATH: "/usr/local/bin:/usr/bin:/bin",
    XDG_RUNTIME_DIR: runtime.display(),
    LIBSEAT_BACKEND: "seatd",
    SEATD_SOCK: "/run/seatd.sock",
  }) {
    let session = spawn process.command_argv(
      /usr/bin/tinyland,
      ["tinyland", "--seat", "--", "/usr/bin/foot", "--", "/bin/xsh", "/usr/lib/laputa/tinyland-foot-read.xsh"],
    )?
    fp"{runtime}/laputa-tinyland.pid".write(f"{session.pid}")
    let _ = wait session
  }
}

main()
