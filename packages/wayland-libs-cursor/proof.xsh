use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "wayland-libs-cursor")
  proof.target_elf(root, p"usr/lib/libwayland-cursor.so.0.26.0", "wayland-libs-cursor")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/usr/lib/libwayland-cursor.so.0.26.0"
  proof.ensure(
    "[libwayland-cursor.so.0]" in dynamic,
    "proof-wayland-libs-cursor",
    "libwayland-cursor has no libwayland-cursor.so.0 SOcursor",
  )
  print "wayland-libs-cursor ok"
}

main(@args)
