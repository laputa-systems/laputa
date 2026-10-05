##! XSH module `proof` package and build operations.
error ProofError = Failed(kind: Str, message: Str)

proc main(root = /rootfs) [fs, error] {
  let db = fp"{root}/var/lib/xsh-pm/packages/laputa-pm/metadata.json"
  let pm = fp"{root}/usr/bin/pm"

  if ! db.exists() {
    return Err(ProofError.Failed(kind: "proof-laputa-pm", message: f"missing package metadata: {db}"))
  }

  if ! pm.exists() {
    return Err(ProofError.Failed(kind: "proof-laputa-pm", message: f"missing pm wrapper: {pm}"))
  }

  print "laputa-pm ok"
}
