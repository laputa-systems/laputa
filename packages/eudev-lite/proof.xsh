##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "eudev-lite")?

  for rel in [p"usr/bin/udevadm", p"usr/bin/udevd", p"usr/lib/udev/systemd-udevd"] {
    proof.target_elf(root, rel, "eudev-lite")?
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print "eudev-lite ok: cross-built"
    return
  }

  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let udevadm = fp"{root}/usr/bin/udevadm"

  # Boot scripts call `udevadm trigger` and `udevadm settle`; both must succeed,
  # and an unsupported subcommand must fail rather than pretend.
  let ver = proof.package_version(root, "eudev-lite")?
  let version = run.text $dynlinker $udevadm "--version" ?
  proof.ensure(version.trim() == ver, "proof-eudev-lite", f"udevadm --version reported {version.trim()}, expected {ver}")?
  run $dynlinker $udevadm "trigger" ?
  run $dynlinker $udevadm "settle" ?
  let info = run.status $dynlinker $udevadm "info" 2> /dev/null
  proof.ensure(! info.ok, "proof-eudev-lite", "udevadm info succeeded without an implementation")?
  print "eudev-lite ok: version, trigger, settle, unsupported subcommand"
}

main(@args)?
