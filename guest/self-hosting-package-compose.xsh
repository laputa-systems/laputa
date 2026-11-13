proc main(root: Path) [fs, process, env, error] -> Result[Unit, Error] {
  assert p"/etc/os-release".read_bytes()? == fp"{root}/inputs/previous-os-release".read_bytes()?
  assert p"/etc/os-release".read_bytes()? != fp"{root}/inputs/development-os-release".read_bytes()?
  let toolchain = fp"{root}/inputs/seed-A"
  for name in ["xsh", "xsht"] {
    assert hash.sha256(fp"/usr/bin/{name}")? == hash.sha256(fp"{toolchain}/{name}")?
  }
  let status = process.run(process.command_argv(p"/usr/bin/xsh", [
    "/usr/bin/xsh", fp"{root}/inputs/laputa/guest/self-hosting-compose.xsh".display(), "--", root.display(), toolchain.display(), fp"{root}/inputs/development-os-release".display(),
  ]))?
  fail "selected package successor failed" unless status.ok
}

main(@args)?
