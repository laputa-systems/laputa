##! XSH module `tinyland` package proof.
use pm.proof
use pm.util as pm_util

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "tinyland")
  let tinyland = fp"{root}/usr/bin/tinyland"
  proof.target_elf(root, p"usr/bin/tinyland", "tinyland")
  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" $tinyland
  proof.ensure("[libseat.so.1]" in dynamic, "proof-tinyland", "tinyland does not link the system libseat")
  proof.ensure("[libxkbcommon.so" in dynamic, "proof-tinyland", "tinyland does not link the system libxkbcommon")

  let strings = tinyland.read_bytes()?.strings()
  proof.ensure("/bin/sh" not in strings, "proof-tinyland", "tinyland still names /bin/sh")

  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"

  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib"}) {
    let version = run.text $dynlinker $tinyland "--help"
    proof.ensure(version.trim().starts_with("usage: tinyland"), "proof-tinyland", f"unexpected help text: {version.trim()}")
  }

  print "tinyland ok"
}
