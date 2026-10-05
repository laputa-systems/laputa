##! XSH module `proof` package and build operations.
use pm.proof

proc main(root: Path = /rootfs) [fs, error] {
  proof.package_metadata(root, "alsa-ucm-conf")
  let share = fp"{root}/usr/share/alsa"
  let ucm = fp"{share}/ucm2"

  # alsa-lib (ALSA_CONFIG_DIR /usr/share/alsa) opens ucm2/ucm.conf first,
  # then finds a card's profile through conf.d/<driver>/<driver>.conf, a
  # symlink into the shared tree, so those links must resolve.
  proof.ensure("Syntax" in fp"{ucm}/ucm.conf".read_text()?, "proof-alsa-ucm-conf", "ucm2/ucm.conf is not a UCM configuration")

  for conf in [p"conf.d/HDA-Intel/HDA-Intel.conf", p"conf.d/USB-Audio/USB-Audio.conf", p"conf.d/SOF/SOF.conf"] {
    let text = fp"{ucm}/{conf}".read_text()?
    proof.ensure("Syntax" in text, "proof-alsa-ucm-conf", f"{conf} is not a UCM configuration")
  }

  # The UCM card scan reads conf.virt.d for virtual cards and fails when the
  # directory is missing; the release keeps it with only a hidden marker file.
  proof.ensure(fs.metadata(fp"{ucm}/conf.virt.d")?.kind == "dir", "proof-alsa-ucm-conf", "missing ucm2/conf.virt.d")

  # Every link in the release resolves to a file inside the installed tree.
  var links = 0
  var files = 0

  for entry in fs.walk(ucm, gitignore: false)? {
    if entry.kind == "symlink" {
      links += 1
      proof.ensure(fs.exists(entry.path)?, "proof-alsa-ucm-conf", f"dangling UCM link {entry.path.relative_to(ucm)}")
    } else if entry.kind == "file" {
      files += 1
    }
  }

  proof.ensure(links == 155 and files == 674, "proof-alsa-ucm-conf", f"ucm2 holds {files} files and {links} links, expected 674 and 155")
  print f"alsa-ucm-conf ok: {files} files, {links} resolving links under /usr/share/alsa/ucm2"
}

main(@args)
