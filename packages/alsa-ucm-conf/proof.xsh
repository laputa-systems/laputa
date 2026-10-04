##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "alsa-ucm-conf")?
  let ucm = fp"{root}/usr/share/alsa/ucm2"

  # alsa-lib finds a card's profile through conf.d/<driver>/<driver>.conf,
  # a symlink into the shared tree, so those links must resolve.
  for conf in [p"conf.d/HDA-Intel/HDA-Intel.conf", p"conf.d/USB-Audio/USB-Audio.conf", p"conf.d/SOF/SOF.conf"] {
    let text = fp"{ucm}/{conf}".read_text()?
    proof.ensure("Syntax" in text, "proof-alsa-ucm-conf", f"{conf} is not a UCM configuration")?
  }

  proof.ensure(fs.exists(fp"{ucm}/ucm.conf")?, "proof-alsa-ucm-conf", "missing ucm2/ucm.conf")?
  print "alsa-ucm-conf ok"
}

main(@args)?
