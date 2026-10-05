##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "dwl-minimal")
  let dwl = fp"{root}/usr/bin/dwl"
  proof.target_elf(root, p"usr/bin/dwl", "dwl-minimal")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" $dwl
  proof.ensure("[libwlroots-0.20.so]" in dynamic, "proof-dwl-minimal", "dwl does not link wlroots 0.20")

  # The startup command runs through execvp, never a shell.
  let strings = dwl.read_bytes()?.strings()
  proof.ensure("/bin/sh" not in strings, "proof-dwl-minimal", "dwl still names /bin/sh")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"dwl-minimal ok: cross-built {pm_util.target_arch()?}"
    return
  }

  # `dwl -v` loads every library dwl links, then prints its version.
  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"

  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib"}) {
    let version = run.text $dynlinker $dwl "-v"
    proof.ensure(version.trim() == "dwl 0.9", "proof-dwl-minimal", f"unexpected dwl version: {version.trim()}")
  }

  print "dwl-minimal ok"
}
