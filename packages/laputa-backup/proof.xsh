##! Installed-payload proof for laputa-backup.
use pm.proof

proc main(root = p"/rootfs") [fs, error] {
  proof.package_metadata(root, "laputa-backup")
  proof.ensure(fp"{root}/usr/lib/laputa/backup.xsh".exists()?, "laputa-backup", "missing backup runner")
  proof.ensure(fp"{root}/usr/lib/laputa/backup-quiesce.xsh".exists()?, "laputa-backup", "missing quiesce hook")
  print "laputa-backup ok"
}
