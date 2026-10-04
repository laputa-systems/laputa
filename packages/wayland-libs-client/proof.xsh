use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "wayland-libs-client")?
  proof.target_elf(root, p"usr/lib/libwayland-client.so.0.26.0", "wayland-libs-client")?
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/usr/lib/libwayland-client.so.0.26.0" ?
  proof.ensure(
    "[libwayland-client.so.0]" in dynamic,
    "proof-wayland-libs-client",
    "libwayland-client has no libwayland-client.so.0 SOclient",
  )?
  print "wayland-libs-client ok"
}

main(@args)?
