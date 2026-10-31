##! XSH module `xinfra` package proof.
use pm.proof

proc main(root = /rootfs) [fs, error] {
  proof.package_metadata(root, "xinfra")

  for member in [p"usr/bin/xinfra", p"usr/lib/xinfra/bin/xinfra.xsh", p"usr/lib/xinfra/lib/xinfra/cli.xsh", p"usr/share/licenses/xinfra/LICENSE"] {
    proof.ensure(fp"{root}/{member}".exists()?, "proof-xinfra", f"missing {member}")
  }

  print "xinfra ok"
}
