proc main(root: Path) [process, error] {
  let status = process.run(process.command_argv(p"/usr/bin/xsh", [
    "/usr/bin/xsh", fp"{root}/inputs/laputa/guest/self-hosting-successor-proof.xsh", "--", root, fp"{root}/inputs/seed-A", fp"{root}/inputs/development-os-release",
  ]))?
  fail "selected package successor behavior failed" unless status.ok
}

main(@args)
