##! XSH module `proof` package and build operations.
use pm.proof

proc main(root = p"/rootfs") [fs, error] {
  proof.package_metadata(root, "font-ttf-hack")
  print "font-ttf-hack ok"
}
