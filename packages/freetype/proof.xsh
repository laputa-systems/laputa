##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "freetype")
  let lib = p"usr/lib/libfreetype.so.6.20.6"
  proof.target_elf(root, lib, "freetype")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}"
  proof.ensure("[libfreetype.so.6]" in dynamic, "proof-freetype", "freetype has no libfreetype.so.6 SONAME")

  # Color emoji glyphs need PNG support, and compressed fonts need zlib; both
  # are optional in upstream's build, so check that they were linked.
  for needed in ["[libpng16.so.16]", "[libz.so.1]"] {
    proof.ensure(needed in dynamic, "proof-freetype", f"freetype does not link {needed}")
  }

  let pc = fp"{root}/usr/lib/pkgconfig/freetype2.pc".read_text()?
  proof.ensure("Version: 26.6.20" in pc, "proof-freetype", "freetype2.pc has the wrong libtool version")
  print "freetype ok"
}

main(@args)
