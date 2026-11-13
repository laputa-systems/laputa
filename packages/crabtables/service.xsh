##! Oneshot that loads /etc/nftables.conf with nfcrt before listeners start.
const nfcrt_bin = p"/usr/bin/nfcrt"
const nfcrt_conf = p"/etc/nftables.conf"

## Argv for the one nfcrt load. A missing ruleset fails closed and runs no nfcrt command.
export pure firewall_plan(conf_present: Bool) -> Result[List[Str], Error] {
  guard conf_present else {
    fail "missing /etc/nftables.conf"
  }

  ["/usr/bin/nfcrt", "-f", "/etc/nftables.conf"]
}

## A non-zero nfcrt status fails the oneshot.
export proc firewall_result(exit_code: Int) [error] -> Result[Unit, Error] {
  guard exit_code == 0 else {
    fail "nfcrt failed"
  }
}

## The xinit service record.
export let service = {
  name: "firewall",
  kind: "oneshot",
  command: process.command_argv(p"/usr/bin/xsh", ["/usr/bin/xsh", "/usr/lib/xinit/services/firewall.xsh"]),
  targets: [
    "boot",
  ],
  logging: "append",
}

## Oneshot entry.
export proc main() [fs, process, error] {
  let argv = firewall_plan(nfcrt_conf.exists()?)?
  let status = process.run(process.command_argv(nfcrt_bin, argv))?
  firewall_result(status.shell_code()?)
}
