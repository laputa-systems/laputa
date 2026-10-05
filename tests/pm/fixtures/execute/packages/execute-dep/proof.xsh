error ProofError = Failed(message: Str)

proc main(root = /rootfs) [fs, error] {
  guard fp"{root}/var/lib/xsh-pm/packages/execute-dep/metadata.json".exists()? else {
    return Err(ProofError.Failed("missing execute-dep metadata"))
  }
}

main(@args)?
