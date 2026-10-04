##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "alsa-utils-minimal")?

  for tool in ["aplay", "amixer", "alsactl"] {
    proof.target_elf(root, fp"usr/bin/{tool}", "alsa-utils-minimal")?
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"alsa-utils-minimal ok: cross-built {pm_util.target_arch()?}"
    return
  }

  # One binary serves every tool name and reports the release under each.
  let os = system.uname()?
  let dynlinker = fp"{root}/usr/lib/ld-musl-{os.machine}.so.1"
  let aplay = run.text $dynlinker fp"{root}/usr/bin/aplay" "--version" ?
  proof.ensure(aplay.trim() == "aplay: version 1.2.16", "proof-alsa-utils-minimal", f"unexpected aplay version: {aplay.trim()}")?
  let alsactl = run.text $dynlinker fp"{root}/usr/bin/alsactl" "--version" ?
  proof.ensure(alsactl.trim() == "alsactl version 1.2.16", "proof-alsa-utils-minimal", f"unexpected alsactl version: {alsactl.trim()}")?
  print "alsa-utils-minimal ok"
}

main(@args)?
