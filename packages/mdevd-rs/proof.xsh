##! XSH module `mdevd-rs` package proof.
use pm.proof
use pm.util as pm_util

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "mdevd-rs")
  proof.target_elf(root, p"usr/bin/mdevd", "mdevd-rs")
  proof.target_elf(root, p"usr/bin/mdevd-coldplug", "mdevd-rs")
  proof.ensure(fp"{root}/usr/lib/xinit/services/mdevd.xsh".exists()?, "proof-mdevd-rs", "missing mdevd service module")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "mdevd-rs ok: cross-built"
    return
  }

  # Run the binary directly like the other Rust proofs: the container loader
  # resolves the musl/libgcc runtime while LD_LIBRARY_PATH supplies the
  # proof root libraries.
  let tmp = fp"{root}/var/tmp/proof-mdevd-rs"
  tmp.remove()
  fp"{tmp}/dev".mkdir(true)
  defer tmp.remove()

  # The live rule set carries no command or firmware lines (the port refuses
  # both by design), so the proof config mirrors real rules only.
  let good = fp"{tmp}/good.conf"
  let bad = fp"{tmp}/bad.conf"

  good.write(
    """null root:root 0666
SUBSYSTEM=input;event[0-9]+ root:input 0660 >input/%1
(ptmx) root:tty 666
""",
  )

  bad.write("null root:root 0666 =\n")

  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib",
  }) {
    run fp"{root}/usr/bin/mdevd" "-N" "-f" $good "-d" fp"{tmp}/dev"
    let rejected = run.status fp"{root}/usr/bin/mdevd" "-N" "-f" $bad "-d" fp"{tmp}/dev" 2> /dev/null
    proof.ensure(
      rejected.exited() and rejected.exit_code()? == 2,
      "proof-mdevd-rs",
      "mdevd -N accepted a configuration with a syntax error",
    )
  }

  print "mdevd-rs ok"
}
