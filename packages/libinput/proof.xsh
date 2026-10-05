##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "libinput")
  let lib = p"usr/lib/libinput.so.10.13.0"
  proof.target_elf(root, lib, "libinput")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" fp"{root}/{lib}"
  proof.ensure("[libinput.so.10]" in dynamic, "proof-libinput", "libinput has no libinput.so.10 SONAME")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"libinput ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let libinput = fp"{root}/usr/bin/libinput"

  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib"}) {
    let version = run.text $dynlinker $libinput "--version"
    proof.ensure(version.trim() == "1.32.0", "proof-libinput", f"unexpected libinput version: {version.trim()}")
  }

  print "libinput ok"
}
