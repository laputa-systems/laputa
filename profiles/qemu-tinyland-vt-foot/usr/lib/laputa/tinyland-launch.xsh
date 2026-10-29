#!/bin/xsh
proc main() [fs, process, env, time, error] {
  let status = json.read(p"/run/xinit/seatd.json")?
  guard json.get(status, ["ready"], false).require(Bool)? else { fail "seatd did not signal readiness" }
  let account = user.lookup("laputa")?
  let runtime = fp"/run/user/{account.uid}"
  let cmdline = p"/proc/cmdline".read_text()?
  let proof = "LAPUTA_QEMU_TINYLAND_FOOT_PROOF=1" in cmdline or "LAPUTA_QEMU_TINYLAND_VT_FOOT_PROOF=1" in cmdline
  if proof {
    var elapsed = 0
    while ! p"/run/tinyland-proof-prepared".exists() {
      guard elapsed < 60 else { fail "proof setup timed out" }
      time.sleep(1s)
      elapsed += 1
    }
  }
  let session = if proof { "/usr/lib/laputa/tinyland-session.xsh" } else { "/usr/lib/laputa/tinyland-interactive.xsh" }
  unix.exec(process.command_argv(/usr/bin/su, ["su", "-p", "laputa", "-s", "/usr/bin/xsh", session], env: {PATH: "/usr/local/bin:/usr/bin:/bin", XDG_RUNTIME_DIR: runtime.display(), LIBSEAT_BACKEND: "seatd", SEATD_SOCK: "/run/seatd.sock"}))?
}
main()
