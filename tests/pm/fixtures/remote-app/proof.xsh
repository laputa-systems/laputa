error ProofError = Failed(kind: Str, message: Str)

proc main(root = /rootfs) [fs, error] {
  let db = fp"{root}/var/lib/xsh-pm/packages/remote-app/metadata.json"

  if ! db.exists()? {
    return Err(ProofError.Failed("proof-remote-app", f"missing package metadata: {db.display()}"))
  }

  print "remote-app ok"
}

main(@args)?
