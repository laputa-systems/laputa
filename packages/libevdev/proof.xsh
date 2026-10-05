##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libevdev")
  let lib = p"usr/lib/libevdev.so.2.3.0"
  proof.target_elf(root, lib, "libevdev")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}"
  proof.ensure("[libevdev.so.2]" in dynamic, "proof-libevdev", "libevdev has no libevdev.so.2 SONAME")

  # The event-name tables come from the recipe's port of make-event-names.py.
  let strings = fp"{root}/{lib}".read_bytes()?.strings()

  for name in ["KEY_ESC", "BTN_SOUTH", "ABS_MT_POSITION_X", "INPUT_PROP_POINTER"] {
    proof.ensure(name in strings, "proof-libevdev", f"libevdev lacks the generated name {name}")
  }

  print "libevdev ok"
}
