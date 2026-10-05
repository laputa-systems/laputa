##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libdrm")
  let lib = p"usr/lib/libdrm.so.2.134.0"
  proof.target_elf(root, lib, "libdrm")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}"
  proof.ensure("[libdrm.so.2]" in dynamic, "proof-libdrm", "libdrm has no libdrm.so.2 SONAME")

  let pc = fp"{root}/usr/lib/pkgconfig/libdrm.pc".read_text()?
  proof.ensure("Version: 2.4.134" in pc, "proof-libdrm", "libdrm.pc has the wrong version")

  # The format-modifier table the recipe generates in place of upstream's
  # Python script supplies drmGetFormatModifierVendor's vendor names.
  let strings = fp"{root}/{lib}".read_bytes()?.strings()
  proof.ensure("ALLWINNER" in strings, "proof-libdrm", "libdrm lacks the generated modifier vendor table")
  print "libdrm ok"
}
