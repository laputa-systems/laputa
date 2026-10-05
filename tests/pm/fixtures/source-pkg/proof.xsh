error ProofError = Failed(kind: Str, message: Str)

proc main(root = /rootfs) [fs, error] {
  let db = fp"{root}/var/lib/xsh-pm/packages/source-pkg/metadata.json"

  if ! db.exists()? {
    return Err(ProofError.Failed("proof-source-pkg", f"missing package metadata: {db.display()}"))
  }

  print "source-pkg ok"
}

main(@args)?
