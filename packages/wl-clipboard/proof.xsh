use pm.proof

proc main(root = p"/rootfs") [fs, error] {
  proof.package_metadata(root, "wl-clipboard")
  print "wl-clipboard ok"
}
