##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "alsa-lib")?
  let lib = p"usr/lib/libasound.so.2"
  proof.target_elf(root, lib, "alsa-lib")?
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}" ?
  proof.ensure("[libasound.so.2]" in dynamic, "proof-alsa-lib", "libasound has no libasound.so.2 SONAME")?
  let symbols = run.text $readelf "--dyn-syms" "-W" fp"{root}/{lib}" ?

  for symbol in ["snd_asoundlib_version", "snd_pcm_open", "snd_pcm_close", "snd_strerror"] {
    proof.ensure(f" {symbol}" in symbols, "proof-alsa-lib", f"libasound does not export {symbol}")?
  }

  # The library and its header report the same release.
  let header = fp"{root}/usr/include/alsa/asoundlib.h".read_text()?
  proof.ensure("#define SND_LIB_VERSION_STR \"1.2.16.1\"" in header, "proof-alsa-lib", "asoundlib.h reports another release")?
  proof.ensure("1.2.16.1" in fp"{root}/{lib}".read_bytes()?.strings(), "proof-alsa-lib", "libasound reports another release")?

  # pkg-config expands ${name} references, so consumers get real paths.
  let pc = fp"{root}/usr/lib/pkgconfig/alsa.pc".read_text()?
  proof.ensure(r"Cflags: -I${includedir}" in pc, "proof-alsa-lib", "alsa.pc does not reference includedir")?
  proof.ensure(r"Libs: -L${libdir} -lasound" in pc, "proof-alsa-lib", "alsa.pc does not reference libdir")?
  print "alsa-lib ok"
}

main(@args)?
