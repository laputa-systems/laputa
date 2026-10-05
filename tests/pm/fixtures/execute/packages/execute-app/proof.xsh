error ProofError = Failed(message: Str)

proc main(root = /rootfs) [fs, error] {
  guard fp"{root}/var/lib/xsh-pm/packages/execute-app/metadata.json".exists()? else {
    return Err(ProofError.Failed("missing execute-app metadata"))
  }

  if ! fp"{root}/usr/share/execute-dep.txt".exists()? {
    return Err(ProofError.Failed("runtime dependency is missing from proof root"))
  }

  if fp"{root}/usr/share/execute-tool.txt".exists()? {
    return Err(ProofError.Failed("build-host dependency leaked into proof root"))
  }
}

main(@args)?
