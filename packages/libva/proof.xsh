##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libva")
  let readelf = proof.readelf_tool()?

  for lib in ["libva", "libva-drm", "libva-wayland"] {
    let rel = fp"usr/lib/{lib}.so.2.2400.0"
    proof.target_elf(root, rel, "libva")
    let dynamic = run.text $readelf "-d" fp"{root}/{rel}" ?
    proof.ensure(f"[{lib}.so.2]" in dynamic, "proof-libva", f"{lib} has no {lib}.so.2 SONAME")
  }

  let pc = fp"{root}/usr/lib/pkgconfig/libva.pc".read_text()?
  proof.ensure("Version: 1.24.0" in pc, "proof-libva", "libva.pc does not report VA-API 1.24.0")
  print "libva ok"
}

main(@args)
