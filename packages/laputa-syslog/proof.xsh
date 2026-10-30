##! XSH module `proof` package and build operations.
use pm.proof

proc main(root = /rootfs) [fs, error] {
  proof.package_metadata(root, "laputa-syslog")
  proof.ensure(fp"{root}/usr/lib/xinit/services/logger.xsh".exists()?, "laputa-syslog", "missing logger service module")
  print "laputa-syslog ok"
}
