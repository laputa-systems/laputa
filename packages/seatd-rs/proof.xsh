##! XSH module `seatd-rs` package proof.
use pm.proof
use pm.util as pm_util

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "seatd-rs")
  let seatd = fp"{root}/usr/bin/seatd"
  proof.target_elf(root, p"usr/bin/seatd", "seatd-rs")
  proof.target_elf(root, p"usr/lib/libseat.so.1", "seatd-rs")
  proof.ensure(fp"{root}/usr/lib/xinit/services/seatd.xsh".exists()?, "proof-seatd-rs", "missing seatd service module")

  let readelf = proof.readelf_tool()?
  let dynamic = run.text $readelf "-d" $seatd
  proof.ensure("[libseat" not in dynamic, "proof-seatd-rs", "the Rust daemon must not depend on the client library")
  proof.ensure("/bin/sh" not in seatd.read_bytes()?.strings(), "proof-seatd-rs", "seatd still names /bin/sh")

  let build_arch = pm_util.build_arch()?
  let target_arch = pm_util.target_arch()?

  if build_arch != target_arch {
    print f"seatd-rs ok: cross-built {target_arch}"
    return
  }

  var version = ""

  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib",
  }) {
    version = run.text $seatd "-v"
  }

  let ver = proof.package_version(root, "seatd-rs")?

  proof.ensure(
    version.trim() == f"seatd version {ver}",
    "proof-seatd-rs",
    f"unexpected seatd version: {version.trim()}",
  )
  print "seatd-rs ok"
}
