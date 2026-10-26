use pm.generation

proc main(root: Path) [fs, process, env, error] -> Result[Unit, Error] {
  assert generation.read_generation_receipt(/)?.profile.name == "qemu-self-hosting"
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  for fixture in ["clock_budget_guest.xsh", "lifecycle_replay_guest.xsh"] {
    let source = fp"{root}/inputs/laputa/xinit/tests/fixtures/{fixture}"
    let status = process.run(process.command_argv(/usr/bin/xsh, ["/usr/bin/xsh", source.display()], env: {
      XSH_ROOT: "/usr/lib/xsh",
      XSH_MODULE_PATH: f"{root}/inputs/laputa:/usr/lib/xsh/core",
    }, timeout: 180s))?
    fail f"disposable guest fixture failed: {fixture}" unless status.ok
  }
  let network = fp"{root}/inputs/laputa/tests/system/fixtures/network-policy-guest.xsh"
  let network_status = process.run(process.command_argv(/usr/bin/xsh, ["/usr/bin/xsh", network.display(), "disposable-vm"], env: {
    XSH_MODULE_PATH: f"{root}/inputs/laputa:/usr/lib/xsh/core",
  }, timeout: 60s))?
  fail "disposable guest network replay failed" unless network_status.ok
  print "LAPUTA_SELF_HOSTING_REPLAYED"
}

main(@args)?
