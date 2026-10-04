use pm.proof

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "wayland-protocols")?
  let pc = fp"{root}/usr/share/pkgconfig/wayland-protocols.pc".read_text()?
  proof.ensure("Version: 1.49" in pc, "proof-wayland-protocols", "wayland-protocols.pc has the wrong version")?

  # Consumers resolve protocol XML through pkgdatadir; check that it names the
  # installed tree and that the tree holds a stable and a staging protocol.
  proof.ensure(
    r"pkgdatadir=${pc_sysrootdir}${datarootdir}/wayland-protocols" in pc,
    "proof-wayland-protocols",
    "wayland-protocols.pc does not name the protocol directory",
  )?

  for rel in [p"stable/xdg-shell/xdg-shell.xml", p"staging/xdg-session-management/xdg-session-management-v1.xml"] {
    let xml = fp"{root}/usr/share/wayland-protocols/{rel}".read_text()?
    proof.ensure("<protocol name=" in xml, "proof-wayland-protocols", f"{rel} is not a protocol description")?
  }

  print "wayland-protocols ok"
}

main(@args)?
