use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "wlroots0.20")
  let lib = p"usr/lib/libwlroots-0.20.so"
  proof.target_elf(root, lib, "wlroots0.20")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}" ?
  proof.ensure("[libwlroots-0.20.so]" in dynamic, "proof-wlroots0.20", "wlroots has no libwlroots-0.20.so SONAME")

  # The built-in feature set the profile relies on: DRM and libinput backends,
  # a session through libseat, and the GBM allocator behind the GLES2 renderer.
  let config = fp"{root}/usr/include/wlroots-0.20/wlr/config.h".read_text()?

  for feature in [
    "WLR_HAS_DRM_BACKEND 1",
    "WLR_HAS_LIBINPUT_BACKEND 1",
    "WLR_HAS_SESSION 1",
    "WLR_HAS_GBM_ALLOCATOR 1",
    "WLR_HAS_GLES2_RENDERER 1",
    "WLR_HAS_XWAYLAND 0",
  ] {
    proof.ensure(feature in config, "proof-wlroots0.20", f"wlr/config.h lacks `{feature}`")
  }

  # The DRM backend names monitor vendors from the table the recipe generates.
  let strings = fp"{root}/{lib}".read_bytes()?.strings()
  proof.ensure("Dell Inc." in strings, "proof-wlroots0.20", "wlroots lacks the generated PNP vendor table")

  let pc = fp"{root}/usr/lib/pkgconfig/wlroots-0.20.pc".read_text()?
  proof.ensure("Version: 0.20.2" in pc, "proof-wlroots0.20", "wlroots-0.20.pc has the wrong version")
  print "wlroots0.20 ok"
}

main(@args)
