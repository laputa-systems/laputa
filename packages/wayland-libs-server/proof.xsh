use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "wayland-libs-server")
  proof.target_elf(root, p"usr/lib/libwayland-server.so.0.26.0", "wayland-libs-server")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/usr/lib/libwayland-server.so.0.26.0" ?
  proof.ensure(
    "[libwayland-server.so.0]" in dynamic,
    "proof-wayland-libs-server",
    "libwayland-server has no libwayland-server.so.0 SOserver",
  )
  print "wayland-libs-server ok"
}

main(@args)
