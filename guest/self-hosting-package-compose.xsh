proc main(root: Path) [fs, process, env, error] {
  assert p"/etc/os-release".read_bytes()? == fp"{root}/inputs/previous-os-release".read_bytes()?
  assert p"/etc/os-release".read_bytes()? != fp"{root}/inputs/development-os-release".read_bytes()?
  let toolchain = fp"{root}/inputs/seed-A"
  for name in ["xsh", "xsht"] {
    assert hash.sha256(fp"/usr/bin/{name}")? == hash.sha256(fp"{toolchain}/{name}")?
  }
  let status = process.run(process.command_argv(p"/usr/bin/xsh", [
    "/usr/bin/xsh", fp"{root}/inputs/laputa/guest/self-hosting-compose.xsh", "--", root, toolchain, fp"{root}/inputs/development-os-release",
  ]))?
  fail "selected package successor failed" unless status.ok
}

main(@args)
