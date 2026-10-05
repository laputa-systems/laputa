use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "mdevd")
  proof.target_elf(root, p"usr/bin/mdevd", "mdevd")
  proof.target_elf(root, p"usr/bin/mdevd-coldplug", "mdevd")
  proof.ensure(fs.exists(fp"{root}/usr/lib/xinit/services/mdevd.xsh")?, "proof-mdevd", "missing mdevd service module")

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "mdevd ok: cross-built"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let mdevd = fp"{root}/usr/bin/mdevd"
  let tmp = fp"{root}/var/tmp/proof-mdevd"
  fs.remove(tmp, missing_ok: true)
  fs.mkdir(fp"{tmp}/dev", true)
  defer fs.remove(tmp, missing_ok: true)?

  # `-N` opens the uevent netlink socket, parses the configuration in both
  # passes, and exits: 0 for a valid file, 2 for a syntax error. That
  # exercises the static skalibs build without touching the host's devices.
  let good = fp"{tmp}/good.conf"
  let bad = fp"{tmp}/bad.conf"

  fs.write(
    good,
    """null root:root 0666
SUBSYSTEM=input;event[0-9]+ root:input 0660 =input/
$MODALIAS=.* root:root 0660 @modprobe -q "$MODALIAS"
""",
  )

  fs.write(bad, "null root:root 0666 =\n")
  run $dynlinker $mdevd "-N" "-f" $good "-d" fp"{tmp}/dev" ?
  let rejected = run.status $dynlinker $mdevd "-N" "-f" $bad "-d" fp"{tmp}/dev" 2> /dev/null
  proof.ensure(rejected.exited() and rejected.exit_code()? == 2, "proof-mdevd", "mdevd -N accepted a configuration with a syntax error")
  print "mdevd ok: configuration parse accepts valid rules and rejects a syntax error"
}

main(@args)
