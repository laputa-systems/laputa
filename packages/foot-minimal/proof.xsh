##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "foot-minimal")
  proof.target_elf(root, p"usr/bin/foot", "foot-minimal")

  # foot answers XTGETTCAP queries from its built-in terminfo, which the
  # recipe vendors; its query-os-name must name the system foot runs on.
  let strings = fp"{root}/usr/bin/foot".read_bytes()?.strings()
  proof.ensure("query-os-name" in strings, "proof-foot-minimal", "foot lacks its built-in terminfo")
  proof.ensure("Darwin" not in strings, "proof-foot-minimal", "foot's built-in terminfo names another OS")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"foot-minimal ok: cross-built {pm_util.target_arch()?}"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"

  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib"}) {
    let version = run.text $dynlinker fp"{root}/usr/bin/foot" "--version" ?
    proof.ensure("1.28.0" in version, "proof-foot-minimal", f"unexpected foot version: {version.trim()}")
  }?

  print "foot-minimal ok"
}

main(@args)
