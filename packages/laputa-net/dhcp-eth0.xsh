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
##! and no other maintained service writes the destination. IPv6 is not
##! supported on this profile: the packaged drop-in disables IPv6
##! autoconfiguration at boot, and `status()` names that unsupported mode with
##! the observed IPv6 cohort so an empty IPv6 state is never silent.

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
  command: process.command_argv(p"/usr/bin/dhcpc", dhcp_argv()),
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
## The IPv6 suffix is always present. `ipv6=unsupported` with `addresses=0
## routes=0 enumerated=1` is the supported report for this profile; any
## deviation reads `ipv6=unexpected`, and a report that cannot run at all reads
## `ipv6=unobserved`, so an empty cohort is never presented as a silent success.
## No IPv6 address, route, or autoconfiguration is requested anywhere.
export proc status() [fs, process, env, error] -> Result[Str, Error] {
  let published = fp"/run/dhcpc/{interface}.status"

  let summary = if ! published.exists() {
    "lease=unknown"
  } else {
    try {
      let report = json.decode(published.read_text()?)?.require(Record)?
      let state = report.get("state")?.require(Str)?
      let address = report.get("address")?
      let prefix = report.get("prefix")?
      if address != null and prefix != null {
        f"lease={state} address={address.require(Str)?}/{prefix.require(Int)?}"
      } else {
        f"lease={state}"
      }
    } ?? "lease=unknown"
  }

  let ipv6 = try {
    ipv6_policy_report()?
  } ?? "ipv6=unobserved"

  Ok(f"{summary} {ipv6}")
}

const ipv6_policy = p"/usr/lib/sysctl.d/20-ipv6.conf"
const ipv6_sysctl = p"/proc/sys/net/ipv6/conf/all/disable_ipv6"

# `unsupported` requires the installed drop-in, the applied kernel switch, a
# complete network observation, and no IPv6 address or route on any interface.
# Anything else is reported as `unexpected` rather than mistaken for a
# configured dual-stack.
proc ipv6_policy_report() [fs, process, env, error] -> Result[Str, Error] {
  let declared = ipv6_policy.exists()?
  var addresses = 0
  var routes = 0
  var enumerated = false
  match linux.network_dump() {
    Ok(dump) => {
      enumerated = true
      for address in dump.addresses {
        if address.family == "inet6" {
          addresses += 1
        }
      }
      for route in dump.routes {
        if route.family == "inet6" {
          routes += 1
        }
      }
    }
    Err(_) => {}
  }
  let applied = ipv6_sysctl.exists()? and ipv6_sysctl.read_text()?.trim() == "1"
  let disabled = declared and applied and enumerated and addresses == 0 and routes == 0
  let verdict = if disabled { "ipv6=unsupported" } else { "ipv6=unexpected" }
  let policy = if declared { "installed" } else { "missing" }
  let switch = if applied { "1" } else { "0" }
  let observed = if enumerated { 1 } else { 0 }
  Ok(f"{verdict} disabled={if disabled { 1 } else { 0 }} policy={policy} sysctl={switch} addresses={addresses} routes={routes} enumerated={observed} source=ra+autoconf")
}
