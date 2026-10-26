proc main(root: Path) [process, error] -> Result[Unit, Error] {
  let network = fp"{root}/inputs/laputa/tests/system/fixtures/network-policy-guest.xsh"
  let status = process.run(process.command_argv(/usr/bin/xsh, ["/usr/bin/xsh", network.display(), "disposable-vm"], env: {
    XSH_MODULE_PATH: f"{root}/inputs/laputa:/usr/lib/xsh/core",
  }, timeout: 60s))?
  fail "disposable guest network replay failed" unless status.ok
  print "LAPUTA_SELF_HOSTING_NETWORK_REPLAYED"
}
main(@args)?
