##! XSH module `proof` package and build operations.
use pm.proof

## A local backup roundtrip through the packaged binary: init a repository
## with a password file, back up one tree, restore it elsewhere, and compare.
## This exercises the manual-restore path, not scheduling or remote backends.
proc main(root = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "rustic")
  proof.ensure(fp"{root}/usr/bin/rustic".exists()?, "rustic", "missing rustic binary")
  let tmp = fp"{root}/var/tmp/proof-rustic"
  tmp.remove()
  tmp.mkdir(true)
  defer tmp.remove()
  let password = fp"{tmp}/password"
  password.write("test-only-rustic-password\n")
  let source = fp"{tmp}/source"
  let restored = fp"{tmp}/restored"
  source.mkdir()
  fp"{source}/payload".write("restic-format roundtrip payload\n")
  let rustic = fp"{root}/usr/bin/rustic"
  let repo = fp"{tmp}/repo"
  let password_value = password.display()
  # Resolve the proof root's own runtime libraries (the gnu-stubs libgcc_s)
  # before any container path, exactly like the doas-rs proof does.
  env ({LD_LIBRARY_PATH: fp"{root}/usr/lib", RUSTIC_PASSWORD_FILE: password_value, RUSTIC_REPOSITORY: repo.display()}) {
    run $rustic init
    run $rustic backup $source
    run $rustic check
    run $rustic restore latest $restored
  }
  var found = false
  for entry in fs.walk(restored, hidden: true) {
    if entry.kind == "file" and entry.name == "payload" {
      proof.ensure(entry.path.read_text()? == "restic-format roundtrip payload\n", "rustic", "restored payload does not match the backup")
      found = true
    }
  }
  proof.ensure(found, "rustic", "restore produced no payload file")
  print "rustic ok"
}
