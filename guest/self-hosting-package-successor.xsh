proc main(root: Path) [process, error] -> Result[Unit, Error] {
  let status = process.run(process.command_argv(p"/usr/bin/xsh", [
    "/usr/bin/xsh", fp"{root}/inputs/laputa/guest/self-hosting-successor-proof.xsh".display(), "--", root.display(), fp"{root}/inputs/seed-A".display(), fp"{root}/inputs/development-os-release".display(),
  ]))?
  fail "selected package successor behavior failed" unless status.ok
}

main(@args)?
