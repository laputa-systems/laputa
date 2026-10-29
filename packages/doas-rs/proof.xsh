##! XSH module `doas-rs` package proof.
use pm.proof
use pm.util as pm_util

error DoasRsProofError = Failed(kind: Str, message: Str)

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "doas-rs")
  proof.target_elf(root, p"usr/bin/doas", "doas-rs")

  let doas_meta = fp"{root}/usr/bin/doas".metadata()?

  if ! doas_meta.setuid {
    return Err(DoasRsProofError.Failed(kind: "proof-doas-rs", message: "doas is not setuid"))
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "doas-rs ok: cross-built"
    return
  }

  # Exercise the policy check mode against throwaway configs. A well-formed
  # rule parses cleanly, a deny rule fails closed, and a syntax error fails
  # closed too. The invoking proof user is irrelevant: parse success needs
  # no identity, and both the deny rule and the syntax error exit nonzero
  # for every user.
  let tmp = fp"{root}/var/tmp/proof-doas-rs"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()

  let good = fp"{tmp}/good.conf"
  let denied = fp"{tmp}/denied.conf"
  let bad = fp"{tmp}/bad.conf"

  good.write("permit nopass root\n")
  denied.write("deny root\n")
  bad.write("permit root args foo\n")

  let doas = fp"{root}/usr/bin/doas"

  env ({
    LD_LIBRARY_PATH: fp"{root}/usr/lib",
  }) {
    run.text $doas "-C" $good
    let closed = run.status $doas "-C" $denied "id" 2> /dev/null
    proof.ensure(
      closed.exited() and closed.exit_code()? != 0,
      "proof-doas-rs",
      "doas -C executed a command the policy denies",
    )
    let rejected = run.status $doas "-C" $bad "id" 2> /dev/null
    proof.ensure(
      rejected.exited() and rejected.exit_code()? != 0,
      "proof-doas-rs",
      "doas -C accepted a configuration with a syntax error",
    )
  }

  print "doas-rs ok"
}
