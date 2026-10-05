use pm.proof
use pm.util as pm_util

error ScriptError = Failed(kind: Str, message: Str)

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  let muon = fp"{rootfs}/usr/bin/muon"

  if ! muon.exists() {
    return Err(ScriptError.Failed(kind: "proof-muon", message: f"missing muon: {muon}"))?
  }

  proof.target_elf(rootfs, p"usr/bin/muon", "muon")

  if pm_util.build_arch()? == pm_util.target_arch()? {
    let out = run.text $muon "version"
    let trimmed = out.trim()

    if trimmed == "" {
      return Err(ScriptError.Failed(kind: "proof-muon", message: "muon version produced no output"))?
    }

    # fontconfig 2.18 requires meson 1.11 semantics.
    if "meson compatibility version 1.11" not in trimmed {
      return Err(ScriptError.Failed(kind: "proof-muon", message: f"muon is not meson 1.11 compatible: {trimmed}"))?
    }

    print "muon ok: "${trimmed}
  } else {
    print "muon ok: cross-built "${pm_util.target_arch()?}
  }
}

main(@args)
