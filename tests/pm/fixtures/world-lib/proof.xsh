error ProofError = Failed(kind: Str, message: Str)

proc main(root = /rootfs) [fs, error] {
  let payload = fp"{root}/usr/share/world-lib.txt"

  if ! payload.exists()? {
    return Err(ProofError.Failed("proof-world-lib", f"missing payload: {payload.display()}"))
  }

  print "world-lib ok"
}

main(@args)?
