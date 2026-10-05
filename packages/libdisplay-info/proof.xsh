##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libdisplay-info")
  let lib = p"usr/lib/libdisplay-info.so.0.4.0"
  proof.target_elf(root, lib, "libdisplay-info")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}" ?
  proof.ensure("[libdisplay-info.so.4]" in dynamic, "proof-libdisplay-info", "libdisplay-info has no libdisplay-info.so.4 SONAME")

  # The PNP ID table the recipe generates from hwdata names monitor vendors.
  let strings = fp"{root}/{lib}".read_bytes()?.strings()

  for vendor in ["Dell Inc.", "Red Hat, Inc."] {
    proof.ensure(vendor in strings, "proof-libdisplay-info", f"libdisplay-info lacks the PNP vendor name {vendor}")
  }

  print "libdisplay-info ok"
}

main(@args)
