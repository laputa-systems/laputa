##! Installed-payload proof for laputa-diagnostics.
use pm.proof

proc main(root = p"/rootfs") [fs, error] {
  proof.package_metadata(root, "laputa-diagnostics")
  proof.ensure(fp"{root}/usr/lib/laputa/diagnostics.xsh".exists()?, "laputa-diagnostics", "missing diagnostics collector")
  proof.ensure(fp"{root}/usr/lib/xinit/services/diagnostics.xsh".exists()?, "laputa-diagnostics", "missing diagnostics service module")
  print "laputa-diagnostics ok"
}
