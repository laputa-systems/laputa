##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libxkbcommon")?
  let lib = p"usr/lib/libxkbcommon.so.0.13.2"
  proof.target_elf(root, lib, "libxkbcommon")?
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}" ?
  proof.ensure("[libxkbcommon.so.0]" in dynamic, "proof-libxkbcommon", "libxkbcommon has no libxkbcommon.so.0 SONAME")?

  # The library looks up keymaps under its built-in root, which must be the
  # xkeyboard-config tree this root ships.
  let strings = fp"{root}/{lib}".read_bytes()?.strings()
  proof.ensure("/usr/share/X11/xkb" in strings, "proof-libxkbcommon", "libxkbcommon has another XKB config root")?
  proof.ensure(
    fs.exists(fp"{root}/usr/share/X11/xkb/rules/evdev")?,
    "proof-libxkbcommon",
    "the XKB config root has no evdev rules",
  )?
  print "libxkbcommon ok"
}

main(@args)?
