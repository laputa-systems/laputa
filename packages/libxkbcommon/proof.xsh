##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libxkbcommon")
  let lib = p"usr/lib/libxkbcommon.so.0.13.2"
  proof.target_elf(root, lib, "libxkbcommon")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}"
  proof.ensure("[libxkbcommon.so.0]" in dynamic, "proof-libxkbcommon", "libxkbcommon has no libxkbcommon.so.0 SONAME")

  # The library looks up keymaps under its built-in root, which must be the
  # xkeyboard-config tree this root ships.
  let strings = fp"{root}/{lib}".read_bytes()?.strings()
  proof.ensure("/usr/share/X11/xkb" in strings, "proof-libxkbcommon", "libxkbcommon has another XKB config root")
  proof.ensure(
    fp"{root}/usr/share/X11/xkb/rules/evdev".exists()?,
    "proof-libxkbcommon",
    "the XKB config root has no evdev rules",
  )

  # Every lookup path must name the installed system, never the build root.
  let pc = fp"{root}/usr/lib/pkgconfig/xkbcommon.pc".read_text()?

  for lookup in ["/usr/share/xkeyboard-config-2.d", "/usr/share/xkeyboard-config.d", "/etc/xkb"] {
    proof.ensure(lookup in strings, "proof-libxkbcommon", f"libxkbcommon does not look up {lookup}")
    proof.ensure(lookup in pc, "proof-libxkbcommon", f"xkbcommon.pc does not name {lookup}")
  }

  proof.ensure("build-root" not in pc, "proof-libxkbcommon", "xkbcommon.pc names the build root")
  proof.ensure(
    [entry for entry in strings if "build-root" in entry] == [],
    "proof-libxkbcommon",
    "libxkbcommon names the build root",
  )
  print "libxkbcommon ok"
}
