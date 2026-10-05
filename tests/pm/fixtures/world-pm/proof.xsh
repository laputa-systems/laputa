error ProofError = Failed(kind: Str, message: Str)

proc main(root = /rootfs) [fs, error] {
  let cat = fp"{root}/usr/bin/cat"

  if ! cat.exists()? {
    return Err(ProofError.Failed("proof-world-pm", f"missing cat link: {cat.display()}"))
  }

  print "world-pm ok"
}

main(@args)?
