##! Installed-payload proof for laputa-timers.
use pm.proof

proc main(root = p"/rootfs") [fs, error] {
  proof.package_metadata(root, "laputa-timers")
  proof.ensure(fp"{root}/usr/lib/laputa/timers.xsh".exists()?, "laputa-timers", "missing timer scheduler")
  proof.ensure(fp"{root}/usr/lib/laputa/timers-run.xsh".exists()?, "laputa-timers", "missing timer entry point")
  proof.ensure(fp"{root}/usr/lib/xinit/services/laputa-timers.xsh".exists()?, "laputa-timers", "missing timer service module")
  proof.ensure(fp"{root}/etc/laputa/timers/jobs.d".is_dir()?, "laputa-timers", "missing timer job directory")
  print "laputa-timers ok"
}
