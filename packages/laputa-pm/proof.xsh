##! XSH module `proof` package and build operations.
error ProofError = Failed(kind: Str, message: Str)

proc main(root = /rootfs) [fs, error] {
  let db = fp"${root}/var/lib/xsh-pm/packages/laputa-pm/metadata.json"
  let pm = fp"${root}/usr/bin/pm"

  if ! fs.exists(db)? {
    return Err(ProofError.Failed("proof-laputa-pm", f"missing package metadata: ${db}"))
  }

  if ! fs.exists(pm)? {
    return Err(ProofError.Failed("proof-laputa-pm", f"missing pm wrapper: ${pm}"))
  }

  print "laputa-pm ok"
}

main(@args)?
