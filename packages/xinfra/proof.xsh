##! XSH module `xinfra` package proof.
use pm.proof

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "xinfra")

  for member in [p"usr/bin/xinfra", p"usr/lib/xinfra/bin/xinfra.xsh", p"usr/lib/xinfra/lib/xinfra/cli.xsh", p"usr/share/licenses/xinfra/LICENSE"] {
    proof.ensure(fp"{root}/{member}".exists()?, "proof-xinfra", f"missing {member}")
  }

  let entry = fp"{root}/usr/lib/xinfra/bin/xinfra.xsh"

  env ({
    XSH_MODULE_PATH: fp"{root}/usr/lib/xinfra/lib".display(),
  }) {
    let version = run.text /bin/xsh $entry "--" "--version"
    proof.ensure(version.trim() == "xinfra 0.1.0", "proof-xinfra", f"unexpected version output: {version}")
  }

  print "xinfra ok"
}
