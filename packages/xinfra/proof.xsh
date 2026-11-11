##! XSH module `xinfra` package proof.
use pm.proof

proc main(root = p"/rootfs") [fs, process, env, error] {
  proof.package_metadata(root, "xinfra")

  for member in [p"usr/bin/xinfra", p"usr/lib/xinfra/bin/xinfra.xsh", p"usr/lib/xinfra/lib/infra/app.xsh", p"usr/lib/xinfra/lib/infra/transport.xsh", p"usr/share/doc/xinfra/docs/ARCHITECTURE.md"] {
    proof.ensure(fp"{root}/{member}".exists()?, "proof-xinfra", f"missing {member}")
  }

  let entry = fp"{root}/usr/lib/xinfra/bin/xinfra.xsh"

  env ({
    XSH_MODULE_PATH: fp"{root}/usr/lib/xinfra/lib".display(),
  }) {
    let usage = run.text xsh $entry "--" "--help"
    proof.ensure(usage.starts_with("usage: xinfra COMMAND"), "proof-xinfra", f"unexpected help output: {usage}")
  }

  print "xinfra ok"
}
