##! Reference xinit service for one interface of the XSH DHCPv4 client.
##!
##! One module per interface: copy this file and change `interface`. The client is
##! a foreground process that holds an exclusive lock on its state file, writes the
##! readiness byte once the interface is resolved and its loop is armed (not once
##! it has a lease), and publishes its lease state in the state directory. Four
##! levels stay separate: the process runs (`state`, `pid`), the client is armed
##! (the notify byte, shown as `ready`), a lease is configured (`lease=` below),
##! and nothing here claims that the Internet is reachable.

const interface = "eth0"

## The xinit service record. Nothing needs the lease: a missing DHCP server must
## not hold back boot, rescue or login, so dependents use `after` at most.
export let service = {
  name: f"dhcp-{interface}",
  kind: "longrun",
  command: process.command_argv("dhcpc", ["dhcpc", "--run-dir", "/run/dhcpc", interface]),
  targets: [
    "boot",
  ],
  readiness: "notify",
  ready_timeout_ms: 5000,
  stop_timeout_ms: 2000,
  restart: {
    mode: "always",
    delay_ms: 500,
    max_delay_ms: 30000,
    stable_after_ms: 10000,
  },
  logging: "append",
}

## Reports the lease state the client published, or that none exists yet. A
## missing or unreadable state file reads as `lease=unknown`, never as a failure.
export proc status() [fs, process, env, error] -> Result[Str, Error] {
  let published = fp"/run/dhcpc/{interface}.status"

  return Ok("lease=unknown") unless published.exists()

  let summary = try {
    let report = json.decode(published.read_text()?)?.require(Record)?
    let state = report.get("state")?.require(Str)?
    let address = report.get("address")?
    let prefix = report.get("prefix")?
    if address != null and prefix != null {
      f"lease={state} address={address.require(Str)?}/{prefix.require(Int)?}"
    } else {
      f"lease={state}"
    }
  }

  Ok(summary ?? "lease=unknown")
}
