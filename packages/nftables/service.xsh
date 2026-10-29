##! Oneshot that loads /etc/nftables.conf before listeners start.
const nft_bin = p"/usr/bin/nft"
const nft_conf = p"/etc/nftables.conf"

## Argv for the one nft load. A missing ruleset fails closed and runs no nft command.
export pure firewall_plan(conf_present: Bool) -> Result[List[Str], Error] {
  guard conf_present else {
    fail "missing /etc/nftables.conf"
  }

  ["/usr/bin/nft", "-f", "/etc/nftables.conf"]
}

## A non-zero nft status fails the oneshot.
export proc firewall_result(exit_code: Int) [error] -> Result[Unit, Error] {
  guard exit_code == 0 else {
    fail "nft failed"
  }
}

## The xinit service record.
export let service = {
  name: "firewall",
  kind: "oneshot",
  command: process.command_argv(/usr/bin/xsh, ["/usr/bin/xsh", "/usr/lib/xinit/services/firewall.xsh"]),
  targets: [
    "boot",
  ],
  logging: "append",
}

## Oneshot entry.
export proc main() [fs, process, error] {
  let argv = firewall_plan(nft_conf.exists()?)?
  let status = process.run(process.command_argv(nft_bin, argv))?
  firewall_result(status.shell_code()?)
}
