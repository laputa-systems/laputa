use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "wayland-dev")
  proof.target_elf(root, p"usr/bin/wayland-scanner", "wayland-dev")

  # Dependents find the scanner through this variable.
  let scanner_pc = fp"{root}/usr/lib/pkgconfig/wayland-scanner.pc".read_text()?
  proof.ensure(r"bindir=${prefix}/bin" in scanner_pc, "proof-wayland-dev", "wayland-scanner.pc has no bindir")
  proof.ensure(
    r"wayland_scanner=${bindir}/wayland-scanner" in scanner_pc,
    "proof-wayland-dev",
    "wayland-scanner.pc does not name the scanner",
  )

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"wayland-dev ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let scanner = fp"{root}/usr/bin/wayland-scanner"
  let protocol = fp"{root}/usr/share/wayland/wayland.xml"

  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib"}) {
    # The scanner reports its version on stderr.
    let version = (run.capture --text $dynlinker $scanner "--version" ?).stderr
    proof.ensure("1.26.0" in version, "proof-wayland-dev", f"unexpected scanner version: {version.trim()}")
    let header = run.text $dynlinker $scanner "client-header" $protocol "/dev/stdout" ?
    proof.ensure(
      "wl_display_get_registry" in header,
      "proof-wayland-dev",
      "scanner did not generate the core client protocol header",
    )
  }

  print "wayland-dev ok"
}

main(@args)
