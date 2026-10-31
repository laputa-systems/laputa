##! Verifies the packaged clock daemon configuration and target binaries.
use pm.proof
use pm.util as pm_util

proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "ntpd-rs")
  for binary in ["ntp-daemon", "ntp-ctl", "ntp-metrics-exporter"] {
    proof.target_elf(root, fp"usr/bin/{binary}", "ntpd-rs")
  }
  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "ntpd-rs ok: cross-built"
    return
  }
  let tmp = fp"{root}/var/tmp/proof-ntpd-rs"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()
  let bad = fp"{tmp}/bad.toml"
  bad.write("[[source]]\nmode = \"pps\"\npath = \"/dev/pps0\"\n")
  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib"}) {
    let ctl = fp"{root}/usr/bin/ntp-ctl"
    run $ctl "validate" "-c" fp"{root}/usr/share/ntpd-rs/ntp.toml"
    let rejected = run.status $ctl "validate" "-c" $bad 2> /dev/null
    proof.ensure(rejected.exited() and rejected.exit_code()? != 0, "proof-ntpd-rs", "unsupported source was accepted")
  }
  print "ntpd-rs ok"
}
