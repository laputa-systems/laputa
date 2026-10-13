use pm.proof

proc main(root = /rootfs) [fs, error] {
  proof.package_metadata(root, "xinit")
  print "xinit ok"
}
