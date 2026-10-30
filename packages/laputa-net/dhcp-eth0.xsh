##! xinit service for the maintained profile's supervised DHCPv4 client on eth0.
##!
##! The client is a foreground process that holds an exclusive lock on its
##! run-dir state, writes the readiness byte once the interface is resolved and
##! its loop is armed (not once it has a lease), and publishes its lease state
##! under /run/dhcpc. Leases persist in /var/lib/dhcpc on the maintained state
##! disk, so a reboot re-requests the remembered lease instead of discovering
##! from scratch. Four levels stay separate: the process runs (`state`, `pid`),
##! the client is armed (the notify byte, shown as `ready`), a lease is
##! configured (`lease=` below), and nothing here claims that the Internet is
##! reachable.
##!
##! This service is the single owner of /etc/resolv.conf through dhcpc's
##! resolver coordinator: the operator static file at /etc/dhcpc/resolv.static
##! is read-only input, per-interface contributions are kept under /run/dhcpc,
##! and no other maintained service writes the destination. IPv6 has no DHCPv6
##! or router-advertisement handling here and stays unsupported on this profile.

const interface = "eth0"

## The exact dhcpc invocation for the maintained profile. Lease state persists
## in /var/lib/dhcpc on the state disk, run state lives in /run/dhcpc, and
## /etc/resolv.conf is composed from the read-only operator static file plus
## this interface's contribution. No other service writes that destination.
export pure dhcp_argv() -> List[Str] {
  ["dhcpc", "--lease-dir", "/var/lib/dhcpc", "--run-dir", "/run/dhcpc", "--resolv-dir", "/etc", "--static-file", "/etc/dhcpc/resolv.static", interface]
}

## The xinit service record. Nothing needs the lease: a missing DHCP server
## must not hold back boot, rescue or login, so nothing takes `need` on this
## service; dependents use `after` at most.
##
## Readiness is notify. The client writes its readiness byte once the
## interface is resolved and its loop is armed, before it acquires a lease;
## `ready` therefore means the process is armed, and the published lease
## state below is the configured level.
export let service = {
  name: f"dhcp-{interface}",
  kind: "longrun",
  command: process.command_argv(/usr/bin/dhcpc, dhcp_argv()),
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
