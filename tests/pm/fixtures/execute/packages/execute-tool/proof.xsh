error ProofError = Failed(message: Str)

proc main(root = p"/rootfs") [fs, error] {
  guard fp"{root}/var/lib/xsh-pm/packages/execute-tool/metadata.json".exists()? else {
    return Err(ProofError.Failed("missing execute-tool metadata"))
  }
}

main(@args)?
