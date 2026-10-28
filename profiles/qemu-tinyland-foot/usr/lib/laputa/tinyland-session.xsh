#!/bin/xsh
##! Unprivileged tinyland session for the qemu-tinyland-foot proof.
##! Runs as laputa: direct device opens must fail, then the brokered
##! session carries the compositor and foot client. Readiness, input, and
##! success markers are owned by the outer guest proof and the host.
error SessionError = DeniedOpen(path: Str)

proc deny_open(path_value: Path) [fs, error] {
  if let Ok(_) = path_value.read_bytes() {
    return Err(SessionError.DeniedOpen(path_value.display()))
  }
}

proc main() [fs, process, env, error] {
  deny_open(p"/dev/dri/card0")?
  deny_open(p"/dev/input/event0")?
  p"/dev/console".write("LAPUTA_TINYLAND_DIRECT_DENIED\n")?
  p"/run/user/1000/laputa-direct-denied".write("denied\n")?
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
    XDG_RUNTIME_DIR: "/run/user/1000",
    LIBSEAT_BACKEND: "seatd",
    SEATD_SOCK: "/run/seatd.sock",
  }) {
    let session = spawn process.command_argv(
      /usr/bin/tinyland,
      ["tinyland", "--seat", "--", "/usr/bin/foot", "--", "/bin/xsh", "/usr/lib/laputa/tinyland-foot-read.xsh"],
    )?
    p"/run/user/1000/laputa-tinyland.pid".write(f"{session.pid}")
    let _ = wait session
  }
}

main()
