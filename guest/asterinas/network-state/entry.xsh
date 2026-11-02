#!/bin/xsh --
error NetworkStateError = Failed(message: Str)

type Attribute = {data: Bytes, kind: Int}

pure attribute_text(attributes: List[Attribute]) -> Str {
  [f"{attribute.kind}:{attribute.data.base64()}" for attribute in attributes].join(",")
}

proc report(label: Str, only_device: Str, link_state: Bool) [fs, process, env, time, net, error] {
  let dump = linux.network_dump()?
  var names: Map[Int, Str] = {}
  for link in dump.links { names[link.ifindex] = link.name ?? "-" }
  let links = dump.links |> where .name != "sit0"
  for link in links |> where only_device == "" or .name == only_device {
    let state = if link_state { f" flags={link.flags} oper={link.operstate ?? 0}" } else { "" }
    eprint --flush f"NET_{label}_LINK {link.name ?? "-"} mtu={link.mtu ?? 0} hw={link.hardware_type}{state}"
  }
  for address in dump.addresses {
    guard only_device == "" or (names.get(address.ifindex) ?? "-") == only_device else { continue }
    eprint --flush f"NET_{label}_ADDR {names.get(address.ifindex) ?? "-"} {address.family} {address.local ?? "-"}/{address.prefix_length} peer={address.address ?? "-"} brd={address.broadcast ?? "-"} scope={address.scope} flags={address.flags} label={address.label ?? "-"}"
  }
  for route in dump.routes {
    let device = if let index = route.output_ifindex { names.get(index) ?? "-" } else { "-" }
    guard only_device == "" or device == only_device else { continue }
    eprint --flush f"NET_{label}_ROUTE {route.family} {route.destination ?? "default"}/{route.destination_prefix_length} via={route.gateway ?? "-"} dev={device} table={route.table} proto={route.protocol} scope={route.scope} type={route.route_type} prio={route.priority ?? 0} src={route.preferred_source ?? "-"} flags={route.flags} tos={route.tos} attrs={attribute_text(route.attributes)}"
  }
  for rule in dump.rules {
    eprint --flush f"NET_{label}_RULE {rule.family} prio={rule.priority ?? 0} table={rule.table} action={rule.action} src={rule.source ?? "-"}/{rule.source_prefix_length} dst={rule.destination ?? "-"}/{rule.destination_prefix_length} flags={rule.flags} attrs={attribute_text(rule.attributes)}"
  }
  for issue in dump.issues { eprint --flush f"NET_{label}_ISSUE {issue.object} {issue.error_kind} errno={issue.errno ?? 0}" }
  eprint --flush f"NET_{label}_COMPLETE {dump.enumeration_succeeded}"
}

pure attribute(kind: Int, data: Bytes) -> Result[Bytes, Error] {
  let length = 4 + data.len()
  let padding = (4 - length % 4) % 4
  Ok(bytes.concat([bytes.pack_le(length, 2)?, bytes.pack_le(kind, 2)?, data, bytes.zero(padding)?]))
}

pure be32(value: Int) -> Result[Bytes, Error] {
  bytes.pack_be(value, 4)
}

pure ipv4(text: Str) -> Result[Int, Error] {
  var value = 0
  for part in text.split(".") { value = value * 256 + part.parse_int()? }
  Ok(value)
}

type Address = {local: Str, prefix: Int, broadcast: Str?}

pure address_payload(ifindex: Int, item: Address, scope: Int, with_broadcast: Bool) -> Result[Bytes, Error] {
  let c = linux.net_constants()
  let header = bytes.concat([bytes.from_ints([c.AF_INET, item.prefix, 0, scope])?, bytes.pack_le(ifindex, 4)?])
  let local = attribute(c.IFA_LOCAL, be32(ipv4(item.local)?)?)?
  let peer = attribute(c.IFA_ADDRESS, be32(ipv4(item.local)?)?)?
  let announced = if let broadcast = item.broadcast { if with_broadcast { attribute(c.IFA_BROADCAST, be32(ipv4(broadcast)?)?)? } else { b"" } } else { b"" }
  Ok(bytes.concat([header, local, peer, announced]))
}

proc send_request(label: Str, kind: Int, flags: Int, payload: Bytes) [process, net, error] {
  match linux.netlink_route_request(kind, flags, payload, 3000) {
    Ok(ack) => eprint --flush f"NET_{label}_ACK errno={ack.errno}"
    Err(error) => eprint --flush f"NET_{label}_ERR {error.message}"
  }
}

proc probe(label: Str, host: Str) [process, net, error] {
  let c = linux.net_constants()
  let fd = linux.socket(c.AF_INET, c.SOCK_STREAM)?
  linux.set_socket_timeout(fd, c.SO_SNDTIMEO, 3000)?
  match linux.connect(fd, {family: "inet", address: host, port: 9}) {
    Ok(_) => eprint --flush f"NET_{label}_PROBE connected"
    Err(error) => eprint --flush f"NET_{label}_PROBE {error.message}"
  }
}

type Route = {destination: Str, prefix: Int, gateway: Str?, priority: Int, protocol: Int}

pure route_payload(ifindex: Int, item: Route, add: Bool) -> Result[Bytes, Error] {
  let c = linux.net_constants()
  let gateway = item.gateway ?? "0.0.0.0"
  let scope = if ! add { c.RT_SCOPE_NOWHERE } else if item.gateway == null { c.RT_SCOPE_LINK } else { c.RT_SCOPE_UNIVERSE }
  let kind = if add { c.RTN_UNICAST } else { 0 }
  let header = bytes.concat([bytes.from_ints([c.AF_INET, item.prefix, 0, 0, c.RT_TABLE_MAIN, item.protocol, scope, kind])?, bytes.zero(4)?])
  let destination = if item.prefix > 0 { attribute(c.RTA_DST, be32(ipv4(item.destination)?)?)? } else { b"" }
  let via = if item.gateway != null { attribute(c.RTA_GATEWAY, be32(ipv4(gateway)?)?)? } else { b"" }
  let device = attribute(c.RTA_OIF, bytes.pack_le(ifindex, 4)?)?
  let priority = attribute(c.RTA_PRIORITY, bytes.pack_le(item.priority, 4)?)?
  Ok(bytes.concat([header, destination, via, device, priority]))
}

proc add_route(label: Str, name: Str, item: Route) [fs, process, env, time, net, error] {
  let c = linux.net_constants()
  let flags = c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK).bit_or(c.NLM_F_CREATE).bit_or(c.NLM_F_EXCL)
  send_request(label, c.RTM_NEWROUTE, flags, route_payload(ifindex_of(name)?, item, true)?)
  report(label, "", false)?
}

proc delete_route(label: Str, name: Str, item: Route) [fs, process, env, time, net, error] {
  let c = linux.net_constants()
  send_request(label, c.RTM_DELROUTE, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK), route_payload(ifindex_of(name)?, item, false)?)
  report(label, "", false)?
}

proc ifindex_of(name: Str) [fs, process, env, time, net, error] -> Result[Int] {
  for link in linux.network_dump()?.links { if link.name == name { return link.ifindex } }
  Err(NetworkStateError.Failed(f"no link {name}"))
}

proc add_address(label: Str, name: Str, item: Address) [fs, process, env, time, net, error] {
  let c = linux.net_constants()
  let flags = c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK).bit_or(c.NLM_F_CREATE).bit_or(c.NLM_F_EXCL)
  send_request(label, c.RTM_NEWADDR, flags, address_payload(ifindex_of(name)?, item, c.RT_SCOPE_UNIVERSE, true)?)
  report(label, "", false)?
}

proc delete_address(label: Str, name: Str, item: Address) [fs, process, env, time, net, error] {
  let c = linux.net_constants()
  send_request(label, c.RTM_DELADDR, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK), address_payload(ifindex_of(name)?, item, c.RT_SCOPE_UNIVERSE, false)?)
  report(label, "", false)?
}

proc wait_for_operstate(name: Str, expected: Int) [fs, process, env, time, net, error] {
  let deadline = time.monotonic()? + 5000000000
  while time.monotonic()? < deadline {
    for link in linux.network_dump()?.links {
      if link.name == name and (link.operstate ?? 0) == expected { return }
    }
    time.sleep(50ms)
  }
  eprint --flush f"NET_TIMEOUT {name} operstate {expected}"
}

proc step(label: Str, name: Str, up: Bool, expected: Int) [fs, process, env, time, net, error] {
  let result = if up { linux.link_up(name) } else { linux.link_down(name) }
  match result {
    Ok(_) => {
      eprint --flush f"NET_{label}_OK"
      wait_for_operstate(name, expected)
    }
    Err(error) => eprint --flush f"NET_{label}_ERR {error.message}"
  }
  report(label, "", true)
}

proc main() [fs, process, env, time, net, error] {
  let mode = p"/usr/lib/asterinas/case/mode".read_text()?.trim()
  eprint --flush f"NET_BEGIN {mode}"
  match mode {
    "loopback" => report("initial", "lo", false)?
    "link" => {
      report("initial", "", true)?
      step("eth0_up", "eth0", true, 6)?
      step("eth0_down", "eth0", false, 2)?
      step("eth0_up_again", "eth0", true, 6)?
      step("lo_down", "lo", false, 2)?
      step("lo_up", "lo", true, 0)?
      step("missing", "missing0", true, 0)?
    }
    "address" => {
      step("up", "eth0", true, 6)?
      let primary: Address = {local: "192.0.2.10", prefix: 24, broadcast: null}
      let second: Address = {local: "192.0.2.77", prefix: 24, broadcast: null}
      let host: Address = {local: "198.51.100.5", prefix: 32, broadcast: null}
      probe("before_address", "192.0.2.1")?
      add_address("add_primary", "eth0", primary)?
      probe("with_address", "192.0.2.1")?
      add_address("add_primary_again", "eth0", primary)?
      add_address("add_second_in_subnet", "eth0", second)?
      add_address("add_host", "eth0", host)?
      delete_address("delete_second", "eth0", second)?
      delete_address("delete_second_again", "eth0", second)?
      step("down", "eth0", false, 2)?
      probe("while_down", "192.0.2.1")?
      step("up_again", "eth0", true, 6)?
      delete_address("delete_primary", "eth0", primary)?
      probe("after_delete", "192.0.2.1")?
      delete_address("delete_host", "eth0", host)?
      add_address("add_primary_for_promotion", "eth0", primary)?
      add_address("add_second_for_promotion", "eth0", second)?
      delete_address("delete_primary_with_secondary", "eth0", primary)?
      let c = linux.net_constants()
      let flags = c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK).bit_or(c.NLM_F_CREATE).bit_or(c.NLM_F_EXCL)
      send_request("missing_link", c.RTM_NEWADDR, flags, address_payload(4242, primary, c.RT_SCOPE_UNIVERSE, true)?)
      send_request("oversized_prefix", c.RTM_NEWADDR, flags, address_payload(ifindex_of("eth0")?, {...primary, prefix: 33}, c.RT_SCOPE_UNIVERSE, true)?)
      send_request("delete_missing_link", c.RTM_DELADDR, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK), address_payload(4242, primary, c.RT_SCOPE_UNIVERSE, false)?)
    }
    "route" => {
      let c = linux.net_constants()
      let address: Address = {local: "192.0.2.10", prefix: 24, broadcast: null}
      let default: Route = {destination: "0.0.0.0", prefix: 0, gateway: "192.0.2.1", priority: 100, protocol: c.RTPROT_DHCP}
      let slower: Route = {...default, priority: 200}
      let network: Route = {destination: "10.20.0.0", prefix: 16, gateway: "192.0.2.1", priority: 0, protocol: c.RTPROT_STATIC}
      let direct: Route = {destination: "192.168.50.0", prefix: 24, gateway: null, priority: 0, protocol: c.RTPROT_STATIC}
      step("up", "eth0", true, 6)?
      add_address("address", "eth0", address)?
      add_route("add_default", "eth0", default)?
      add_route("add_default_again", "eth0", default)?
      add_route("add_slower_default", "eth0", slower)?
      add_route("add_network", "eth0", network)?
      add_route("add_direct", "eth0", direct)?
      add_route("add_unreachable_gateway", "eth0", {...network, destination: "10.99.0.0", gateway: "172.16.0.1"})?
      add_route("add_host_bits", "eth0", {...network, destination: "10.20.0.5"})?
      send_request("add_missing_link", c.RTM_NEWROUTE, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK).bit_or(c.NLM_F_CREATE).bit_or(c.NLM_F_EXCL), route_payload(4242, network, true)?)
      delete_route("delete_default", "eth0", default)?
      delete_route("delete_default_again", "eth0", default)?
      delete_route("delete_network_by_destination", "eth0", {...network, priority: 0})?
      step("down", "eth0", false, 2)?
      step("up_again", "eth0", true, 6)?
      add_route("add_while_down_default", "eth0", default)?
      delete_address("delete_address_keeps_routes", "eth0", address)?
      delete_route("delete_slower_default", "eth0", slower)?
      add_route("add_without_address", "eth0", default)?
    }
    other => fail f"unknown network-state mode {other}"
  }
  eprint --flush "NET_DONE"
}
main()
