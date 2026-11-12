proc main(root: Path) [process, error] -> Result[Unit, Error] {
  let status = process.run(process.command_argv(p"/usr/bin/xsh", [
    "/usr/bin/xsh", fp"{root}/inputs/laputa/guest/self-hosting-preserved-proof.xsh".display(), "--", root.display(), fp"{root}/inputs/previous-os-release".display(),
  ]))?
  fail "previous installed package changed" unless status.ok
}

main(@args)?
