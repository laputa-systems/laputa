##! XSH module `proof` package and build operations.
use pm.proof

proc main(root = /rootfs) [fs, error] {
  proof.package_metadata(root, "baselayout")
  proof.ensure(
    fp"{root}/usr/lib/sysctl.d/10-terminal.conf".read_text()?.trim() == "dev.tty.legacy_tiocsti = 0",
    "proof-baselayout",
    "terminal injection must be disabled before user sessions",
  )
  print "baselayout ok"
}
