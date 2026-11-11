#!/bin/xsh
##! Root control agent for the DHCP lifecycle guest. It reads one JSON request
##! per line from a virtio-serial port, executes a fixed set of observations and
##! privileged fixture actions, and answers with one JSON line. The host test
##! owns the other end of the port; this agent never uses the network under test.

proc control_port() -> Result[Path, Error] {
  for candidate in [p"/dev/vport0p1", p"/dev/virtio-ports/laputa-ctl", p"/dev/vport1p1", p"/dev/vport2p1"] {
    if candidate.exists()? { return Ok(candidate) }
  }
  for entry in fs.children(p"/dev")? {
    if entry.name.starts_with("vport") and entry.name.ends_with("p1") { return Ok(entry.path) }
  }
  Err(error.failure("no virtio-serial control port"))
}

proc reply(fd: Int, value: Any) -> Result[Unit, Error] {
  let _ = unix.write_fd(fd, bytes.from_text(json.encode(value)? + "\n"))?
}

proc text_of(source: Path, limit: Int) -> Result[Str, Error] {
  return Ok("") unless source.exists()?
  let text = source.read_text()?
  return Ok(text) when text.byte_len() <= limit
  Ok(text[..limit])
}

proc carrier_of(operstate: Str) -> Result[Str, Error] {
  return Ok("0") when operstate.trim() == "down"
  text_of(p"/sys/class/net/eth0/carrier", 32)
}

proc read_line(fd: Int) -> Result[Str, Error] {
  var buffer = b""
  while true {
    let ready = unix.poll_fd(fd, ["readable"], 1000)?
    if ready != ["readable"] {
      continue
    }
    let chunk = unix.read_fd(fd, 1)?
    if chunk.is_empty() {
      return Err(error.failure("the control port closed"))
    }
    if chunk.byte_at(0) == 10 {
      return buffer.utf8()?
    }
    buffer = bytes.concat([buffer, chunk])
    if buffer.len() > 65536 {
      return Err(error.failure("the control line is too long"))
    }
  }
  Err(error.failure("unreachable"))
}

proc optional_json(source: Path) -> Result[Any, Error] {
  return Ok(null) unless source.exists()?
  json.read(source)
}

proc observation() -> Result[Record, Error] {
  let dump = linux.network_dump()?
  var links: List[Record] = []
  for link in dump.links {
    links += [{ifindex: link.ifindex, name: link.name, kind: link.kind, flags: link.flags, operstate: link.operstate}]
  }
  var addresses: List[Record] = []
  for address in dump.addresses {
    addresses += [{ifindex: address.ifindex, family: address.family, local: address.local, prefix: address.prefix_length, scope: address.scope, flags: address.flags}]
  }
  var routes: List[Record] = []
  for route in dump.routes {
    var hops: List[Record] = []
    for hop in route.nexthops {
      hops += [{ifindex: hop.ifindex, gateway: hop.gateway}]
    }
    routes += [{family: route.family, table: route.table, destination: route.destination, prefix: route.destination_prefix_length, priority: route.priority, protocol: route.protocol, scope: route.scope, route_type: route.route_type, output_ifindex: route.output_ifindex, gateway: route.gateway, hops: hops}]
  }
  let operstate = text_of(p"/sys/class/net/eth0/operstate", 32)?
  let lease_dir = p"/var/lib/dhcpc"
  var leases: List[Str] = []
  if lease_dir.exists()? {
    for entry in fs.children(lease_dir)? {
      leases += [entry.name]
    }
  }
  {
    status: optional_json(p"/run/dhcpc/eth0.status")?,
    service: optional_json(p"/run/xinit/dhcp-eth0.json")?,
    health: optional_json(p"/run/laputa-health.json")?,
    resolv: text_of(p"/etc/resolv.conf", 8192)?,
    carrier: carrier_of(operstate)?,
    operstate: operstate,
    ifindex: text_of(p"/sys/class/net/eth0/ifindex", 32)?,
    enumerated: dump.enumeration_succeeded,
    state: dump.state,
    links: links,
    addresses: addresses,
    routes: routes,
    leases: leases,
  }
}

proc virtio_net_device() -> Result[Path, Error] {
  for entry in fs.children(p"/sys/bus/pci/devices")? {
    if fp"{entry.path}/vendor".read_text()?.trim() == "0x1af4" and fp"{entry.path}/device".read_text()?.trim() == "0x1000" {
      return Ok(entry.path)
    }
  }
  Err(error.failure("no virtio-net PCI device"))
}

proc restart_dhcp() -> Result[Record, Error] {
  let service = optional_json(p"/run/xinit/dhcp-eth0.json")?
  guard service != null else { return Err(error.failure("the dhcp-eth0 status file is absent")) }
  let pid = json.get(service, ["pid"], 0).require(Int)?
  guard pid > 0 else { return Err(error.failure("dhcp-eth0 has no process")) }
  process.kill(pid, signal: "TERM")?
  Ok({killed: pid})
}

proc nic_cycle() -> Result[Record, Error] {
  let before = text_of(p"/sys/class/net/eth0/ifindex", 32)?
  let device = virtio_net_device()?
  fp"{device}/remove".write("1")?
  var waited = 0
  while p"/sys/class/net/eth0".exists()? and waited < 5000 {
    time.sleep(10ms)
    waited += 10
  }
  guard ! p"/sys/class/net/eth0".exists()? else { return Err(error.failure("the network interface did not disappear")) }
  time.sleep(300ms)
  p"/sys/bus/pci/rescan".write("1")?
  waited = 0
  while ! p"/sys/class/net/eth0".exists()? and waited < 10000 {
    time.sleep(10ms)
    waited += 10
  }
  guard p"/sys/class/net/eth0".exists()? else { return Err(error.failure("the network interface did not reappear")) }
  let after = text_of(p"/sys/class/net/eth0/ifindex", 32)?
  Ok({device: device.display(), ifindex_before: before, ifindex_after: after})
}

proc ntp_status() -> Result[Record, Error] {
  let out = p"/run/ntp-offline-ctl.out"
  let err = p"/run/ntp-offline-ctl.err"
  let config = p"/usr/share/ntpd-rs/ntp.toml"
  let status = process.run(process.command_argv(p"/usr/bin/ntp-ctl", ["ntp-ctl", "status", "-c", f"{config}"], p"/", {}, b"", out, err, timeout: 15s))?
  Ok({
    service: optional_json(p"/run/xinit/ntpd-rs.json")?,
    log: text_of(p"/var/log/ntpd-rs/current", 65536)?,
    ctl_exit: status.exit_code()?,
    ctl: text_of(out, 16384)?,
    ctl_error: text_of(err, 4096)?,
  })
}

proc resolve(name: Str) -> Result[Record, Error] {
  let out = p"/run/dhcp-lifecycle-getent.out"
  let err = p"/run/dhcp-lifecycle-getent.err"
  let status = process.run(process.command_argv(p"/usr/bin/host", ["host", name], p"/", {}, b"", out, err, timeout: 15s))?
  Ok({exit: status.exit_code()?, stdout: text_of(out, 8192)?.trim(), stderr: text_of(err, 8192)?.trim()})
}

proc ipv6_state() -> Result[Record, Error] {
  let dump = linux.network_dump()?
  var addresses = 0
  var routes = 0
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
  let policy = p"/usr/lib/sysctl.d/20-ipv6.conf"
  let all_switch = p"/proc/sys/net/ipv6/conf/all/disable_ipv6"
  let default_switch = p"/proc/sys/net/ipv6/conf/default/disable_ipv6"
  let accept_ra = p"/proc/sys/net/ipv6/conf/all/accept_ra"
  let autoconf = p"/proc/sys/net/ipv6/conf/all/autoconf"
  Ok({
    policy: policy.exists()?,
    all_switch: text_of(all_switch, 8)?.trim(),
    default_switch: text_of(default_switch, 8)?.trim(),
    accept_ra: text_of(accept_ra, 8)?.trim(),
    autoconf: text_of(autoconf, 8)?.trim(),
    addresses,
    routes,
    enumeration: dump.enumeration_succeeded,
  })
}

proc handle(fd: Int, line: Str) -> Result[Unit, Error] {
  let request = json.decode(line)?.require(Record)?
  let op = json.get(request, ["op"], "").require(Str)?
  if op == "ping" {
    reply(fd, {ok: true})?
  } else if op == "status" {
    reply(fd, {ok: true, observation: observation()?})?
  } else if op == "restart-dhcp" {
    reply(fd, {ok: true, result: restart_dhcp()?})?
  } else if op == "nic-cycle" {
    reply(fd, {ok: true, result: nic_cycle()?})?
  } else if op == "resolve" {
    let name = json.get(request, ["name"], "").require(Str)?
    reply(fd, {ok: true, result: resolve(name)?})?
  } else if op == "ipv6" {
    reply(fd, {ok: true, result: ipv6_state()?})?
  } else if op == "ntp" {
    reply(fd, {ok: true, result: ntp_status()?})?
  } else if op == "log" {
    reply(fd, {ok: true, result: text_of(p"/var/log/dhcp-eth0/current", 32768)?})?
  } else {
    reply(fd, {ok: false, error: f"unknown operation {op}"})?
  }
}

proc main() -> Result[Unit, Error] {
  let port = control_port()?
  let control = unix.open_fd(port, write: true, nonblock: false)?
  p"/dev/console".write(f"LAPUTA_DHCP_AGENT_READY {port.display()}\n")?
  loop {
    let line = read_line(control)?
    if line.trim() == "" {
      continue
    }
    match handle(control, line) {
      Ok(_) => {}
      Err(problem) => {
        let _ = reply(control, {ok: false, error: problem.message})
      }
    }
  }
  Ok()
}

match main() {
  Ok(_) => {}
  Err(problem) => {
    let _ = p"/dev/console".write(f"LAPUTA_DHCP_AGENT_FAILED {problem.message}\n")
  }
}
