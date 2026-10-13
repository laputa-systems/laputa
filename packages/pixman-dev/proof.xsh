use pm.proof

proc main(root = /rootfs) [fs, error] {
  proof.package_metadata(root, "pixman-dev")
  print "pixman-dev ok"
}
