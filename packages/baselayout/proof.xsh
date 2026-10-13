##! XSH module `proof` package and build operations.
use pm.proof

proc main(root = /rootfs) [fs, error] {
  proof.package_metadata(root, "baselayout")
  print "baselayout ok"
}
