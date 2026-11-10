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

proc ip_step(label: Str, name: Str, state_word: Str, expected: Int) [fs, process, env, time, net, error] {
  let output = p"/run/ip-link.out"
  let status = process.run(process.command_argv(p"/usr/bin/xsh", [p"/usr/bin/xsh", p"/usr/lib/xsh/core/ip", "link", "set", "dev", name, state_word], p"/", {XSH_MODULE_PATH: "/usr/lib/xsh/core", LC_ALL: "C"}, b"", output, output))?
  if status.ok {
    eprint --flush f"NET_{label}_OK"
    wait_for_operstate(name, expected)
  } else {
    eprint --flush f"NET_{label}_ERR {output.read_text()?.trim()}"
  }
  report(label, "", true)
}

pure attributes_of(payload: Bytes, start: Int) -> List[Attribute] {
  var offset = start
  let found: List[Attribute] = collect {
    while offset + 4 <= payload.len() {
      let length = bytes.unpack_le(payload, 2, offset) ?? 0
      let kind = bytes.unpack_le(payload, 2, offset + 2) ?? 0
      break when length < 4 or offset + length > payload.len()
      yield {kind: kind.bit_and(16383), data: payload[offset + 4..offset + length]}
      offset += (length + 3) / 4 * 4
    }
  }
  found
}

pure attribute_of(attributes: List[Attribute], kind: Int) -> Bytes? {
  for attribute in attributes { return attribute.data when attribute.kind == kind }
  null
}

pure address_of(attributes: List[Attribute], kind: Int) -> Str {
  if let data = attribute_of(attributes, kind) {
    if data.len() == 4 { return f"{data.byte_at(0) ?? 0}.{data.byte_at(1) ?? 0}.{data.byte_at(2) ?? 0}.{data.byte_at(3) ?? 0}" }
  }
  "-"
}

pure number_of(attributes: List[Attribute], kind: Int, width: Int) -> Int {
  if let data = attribute_of(attributes, kind) { return bytes.unpack_le(data, width) ?? 0 }
  0
}

pure origin_of(message: Bytes) -> Result[Str, Error] {
  let seq = bytes.unpack_le(message, 4, 8)?
  let pid = bytes.unpack_le(message, 4, 12)?
  Ok(f"seq={if seq == 0 { "0" } else { "request" }} pid={if pid == 0 { "0" } else { "request" }} hdr={bytes.unpack_le(message, 2, 6)?}")
}

pure describe_event(message: Bytes, names: Map[Int, Str]) -> Result[Str, Error] {
  let kind = bytes.unpack_le(message, 2, 4)?
  let origin = origin_of(message)?
  if kind == 16 {
    let attributes = attributes_of(message, 32)
    let index = bytes.unpack_le(message, 4, 20)?
    return Ok(f"NEWLINK {names.get(index) ?? "?"} up={bytes.unpack_le(message, 4, 24)?.bit_and(1)} change={bytes.unpack_le(message, 4, 28)?} mtu={number_of(attributes, 4, 4)} {origin}")
  }
  if kind == 20 or kind == 21 {
    let attributes = attributes_of(message, 24)
    let index = bytes.unpack_le(message, 4, 20)?
    let name = if kind == 20 { "NEWADDR" } else { "DELADDR" }
    return Ok(f"{name} {names.get(index) ?? "?"} {address_of(attributes, 2)}/{message.byte_at(17) ?? 0} flags={message.byte_at(18) ?? 0} scope={message.byte_at(19) ?? 0} brd={address_of(attributes, 4)} {origin}")
  }
  if kind == 24 or kind == 25 {
    let attributes = attributes_of(message, 28)
    let name = if kind == 24 { "NEWROUTE" } else { "DELROUTE" }
    let device = names.get(number_of(attributes, 4, 4)) ?? "?"
    return Ok(f"{name} {address_of(attributes, 1)}/{message.byte_at(17) ?? 0} table={number_of(attributes, 15, 4)} proto={message.byte_at(21) ?? 0} scope={message.byte_at(22) ?? 0} type={message.byte_at(23) ?? 0} dev={device} via={address_of(attributes, 5)} src={address_of(attributes, 7)} prio={number_of(attributes, 6, 4)} {origin}")
  }
  Ok(f"TYPE {kind}")
}

proc drain_events(label: Str, listener: Int) [fs, process, env, time, net, error] {
  var names: Map[Int, Str] = {}
  for link in linux.network_dump()?.links { names[link.ifindex] = link.name ?? "-" }
  while unix.poll_fd(listener, ["readable"], 300)? == ["readable"] {
    match unix.read_fd(listener, 65536) {
      Ok(message) => {
        let late_link_state = bytes.unpack_le(message, 2, 4)? == 16 and bytes.unpack_le(message, 4, 28)? == 0
        if !late_link_state { eprint --flush f"NET_{label}_EVENT {describe_event(message, names)?}" }
      }
      Err(error) => eprint --flush f"NET_{label}_EVENT_ERR {error.errno ?? 0}"
    }
  }
}

pure ip_text(data: Bytes, offset: Int) -> Str {
  f"{data.byte_at(offset) ?? 0}.{data.byte_at(offset + 1) ?? 0}.{data.byte_at(offset + 2) ?? 0}.{data.byte_at(offset + 3) ?? 0}"
}

pure describe_frame(frame: Bytes) -> Result[Str?, Error] {
  let ethertype = bytes.unpack_be(frame, 2, 12)?
  let destination = if frame[0..6] == b"\xff\xff\xff\xff\xff\xff" { "broadcast" } else { "unicast" }
  if ethertype == 2054 {
    let operation = bytes.unpack_be(frame, 2, 20)?
    let sender = ip_text(frame, 28)
    let peer_checks_neighbor = operation == 1 and sender == "192.0.2.1"
    let answer_to_peer_check = operation == 2 and sender == "192.0.2.10" and destination == "unicast"
    if peer_checks_neighbor or answer_to_peer_check { return Ok(null) }
    return Ok(f"ARP op={bytes.unpack_be(frame, 2, 20)?} {ip_text(frame, 28)}>{ip_text(frame, 38)} dst={destination} len={frame.len()}")
  }
  if ethertype == 2048 {
    let protocol = frame.byte_at(23) ?? 0
    let header = (frame.byte_at(14) ?? 0).bit_and(15) * 4
    let detail = if protocol == 6 { f" flags={(frame.byte_at(14 + header + 13) ?? 0).bit_and(23)}" } else { "" }
    return Ok(f"IPV4 proto={protocol} {ip_text(frame, 26)}>{ip_text(frame, 30)} dst={destination}{detail}")
  }
  Ok(null)
}

pure packet_address(ifindex: Int, protocol: Int, destination: Bytes) -> Result[Bytes, Error] {
  bytes.concat([bytes.pack_le(17, 2)?, bytes.pack_be(protocol, 2)?, bytes.pack_le(ifindex, 4)?, bytes.pack_le(0, 2)?, bytes.from_ints([0, destination.len()])?, destination, bytes.zero(8 - destination.len())?])
}

pure arp_request(mac: Bytes, sender: List[Int], target: List[Int]) -> Result[Bytes, Error] {
  bytes.concat([b"\xff\xff\xff\xff\xff\xff", mac, bytes.pack_be(2054, 2)?, bytes.pack_be(1, 2)?, bytes.pack_be(2048, 2)?, bytes.from_ints([6, 4])?, bytes.pack_be(1, 2)?, mac, bytes.from_ints(sender)?, bytes.zero(6)?, bytes.from_ints(target)?])
}

pure broadcast_udp(mac: Bytes) -> Result[Bytes, Error] {
  let payload = b"\x01\x02\x03\x04"
  bytes.concat([b"\xff\xff\xff\xff\xff\xff", mac, bytes.pack_be(2048, 2)?, bytes.from_ints([69, 0])?, bytes.pack_be(32, 2)?, bytes.zero(4)?, bytes.from_ints([64, 17])?, bytes.zero(2)?, bytes.zero(4)?, bytes.from_ints([255, 255, 255, 255])?, bytes.pack_be(68, 2)?, bytes.pack_be(67, 2)?, bytes.pack_be(12, 2)?, bytes.zero(2)?, payload])
}

proc open_packet_socket(protocol: Int, ifindex: Int) [process, net, error] -> Result[Int, Error] {
  let c = linux.net_constants()
  let socket = linux.socket(c.AF_PACKET, c.SOCK_RAW.bit_or(c.SOCK_NONBLOCK), bytes.unpack_le(bytes.pack_be(protocol, 2)?, 2)?)?
  if ifindex != 0 { linux.bind(socket, packet_address(ifindex, protocol, b"")?)? }
  Ok(socket)
}

proc drain_packets(label: Str, socket: Int) [fs, process, env, time, net, error] {
  var quiet = false
  while !quiet {
    if unix.poll_fd(socket, ["readable"], 300)? == [] {
      quiet = true
    } else {
      match unix.read_fd(socket, 2048) {
        Ok(frame) => {
          if let text = describe_frame(frame)? { eprint --flush f"NET_{label}_FRAME {text}" }
        }
        Err(error) => {
          eprint --flush f"NET_{label}_RECV_ERR errno={error.errno ?? 0}"
        }
      }
    }
  }
}

pure sockaddr_in(family: Int, octets: List[Int]) -> Result[Bytes, Error] {
  bytes.concat([bytes.pack_le(family, 2)?, bytes.zero(2)?, bytes.from_ints(octets)?, bytes.zero(8)?])
}

pure ifreq(name: Str, tail: Bytes) -> Result[Bytes, Error] {
  let raw = bytes.from_text(name)
  Ok(bytes.concat([raw, bytes.zero(16 - raw.len())?, tail, bytes.zero(24 - tail.len())?]))
}

proc ioctl_result(label: Str, result: Result[Bytes, Error]) [process] {
  match result {
    Ok(_) => eprint --flush f"NET_{label}_ACK errno=0"
    Err(error) => eprint --flush f"NET_{label}_ERR errno={error.errno ?? 0}"
  }
}

proc address_ioctl(label: Str, fd: Int, request: Int, name: Str, family: Int, octets: List[Int]) [process, net, error] {
  ioctl_result(label, linux.ioctl(fd, request, ifreq(name, sockaddr_in(family, octets)?)?, 0))
}

proc route_ioctl(label: Str, operation: Str, destination: Str, genmask: Str, gateway: Str, device: Str) [process, error] {
  let text = run.text /usr/lib/asterinas/case/ioctl-route-probe ${label} ${operation} ${destination} ${genmask} ${gateway} ${device}
  eprint --flush text.trim()
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
    "netlink-link" => {
      report("initial", "", true)?
      ip_step("eth0_up", "eth0", "up", 6)?
      ip_step("eth0_down", "eth0", "down", 2)?
      ip_step("eth0_down_again", "eth0", "down", 2)?
      ip_step("eth0_up_again", "eth0", "up", 6)?
      ip_step("lo_down", "lo", "down", 2)?
      ip_step("lo_up", "lo", "up", 0)?
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
    "events" => {
      let c = linux.net_constants()
      let listener = linux.netlink_open(c.NETLINK_ROUTE, c.RTMGRP_LINK.bit_or(c.RTMGRP_IPV4_IFADDR).bit_or(c.RTMGRP_IPV4_ROUTE))?
      defer unix.close_fd(listener)
      let flags = c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK).bit_or(c.NLM_F_CREATE).bit_or(c.NLM_F_EXCL)
      let primary: Address = {local: "192.0.2.10", prefix: 24, broadcast: null}
      let second: Address = {local: "192.0.2.77", prefix: 24, broadcast: null}
      let host: Address = {local: "198.51.100.5", prefix: 32, broadcast: null}
      let default: Route = {destination: "0.0.0.0", prefix: 0, gateway: "192.0.2.1", priority: 100, protocol: c.RTPROT_DHCP}
      let direct: Route = {destination: "192.168.50.0", prefix: 24, gateway: null, priority: 0, protocol: c.RTPROT_STATIC}
      let index = ifindex_of("eth0")?
      linux.link_up("eth0")?
      drain_events("up", listener)?
      linux.link_up("eth0")?
      drain_events("up_again", listener)?
      send_request("add_primary", c.RTM_NEWADDR, flags, address_payload(index, primary, c.RT_SCOPE_UNIVERSE, true)?)
      drain_events("add_primary", listener)?
      send_request("add_second", c.RTM_NEWADDR, flags, address_payload(index, second, c.RT_SCOPE_UNIVERSE, true)?)
      drain_events("add_second", listener)?
      send_request("add_host", c.RTM_NEWADDR, flags, address_payload(index, host, c.RT_SCOPE_UNIVERSE, true)?)
      drain_events("add_host", listener)?
      send_request("add_default", c.RTM_NEWROUTE, flags, route_payload(index, default, true)?)
      drain_events("add_default", listener)?
      send_request("add_default_again", c.RTM_NEWROUTE, flags, route_payload(index, default, true)?)
      drain_events("add_default_again", listener)?
      send_request("add_direct", c.RTM_NEWROUTE, flags, route_payload(index, direct, true)?)
      drain_events("add_direct", listener)?
      send_request("delete_direct", c.RTM_DELROUTE, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK), route_payload(index, direct, false)?)
      drain_events("delete_direct", listener)?
      send_request("delete_second", c.RTM_DELADDR, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK), address_payload(index, second, c.RT_SCOPE_UNIVERSE, false)?)
      drain_events("delete_second", listener)?
      linux.link_down("eth0")?
      drain_events("down", listener)?
      linux.link_up("eth0")?
      drain_events("up_with_addresses", listener)?
      send_request("add_default_again_after_up", c.RTM_NEWROUTE, flags, route_payload(index, default, true)?)
      drain_events("add_default_again_after_up", listener)?
      send_request("delete_primary", c.RTM_DELADDR, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK), address_payload(index, primary, c.RT_SCOPE_UNIVERSE, false)?)
      drain_events("delete_primary", listener)?
      send_request("delete_last_address", c.RTM_DELADDR, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK), address_payload(index, host, c.RT_SCOPE_UNIVERSE, false)?)
      drain_events("delete_last_address", listener)?
      report("after_last_address", "eth0", false)?
      send_request("add_primary_for_promotion", c.RTM_NEWADDR, flags, address_payload(index, primary, c.RT_SCOPE_UNIVERSE, true)?)
      send_request("add_second_for_promotion", c.RTM_NEWADDR, flags, address_payload(index, second, c.RT_SCOPE_UNIVERSE, true)?)
      drain_events("add_for_promotion", listener)?
      send_request("delete_primary_with_secondary", c.RTM_DELADDR, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK), address_payload(index, primary, c.RT_SCOPE_UNIVERSE, false)?)
      drain_events("delete_primary_with_secondary", listener)?
      linux.link_down("eth0")?
      drain_events("down_without_addresses", listener)?
      send_request("add_primary_while_down", c.RTM_NEWADDR, flags, address_payload(index, primary, c.RT_SCOPE_UNIVERSE, true)?)
      drain_events("add_primary_while_down", listener)?
      linux.link_up("eth0")?
      drain_events("up_last", listener)?
    }
    "packet" => {
      let primary: Address = {local: "192.0.2.10", prefix: 24, broadcast: null}
      step("up", "eth0", true, 6)?
      add_address("address", "eth0", primary)?
      let index = ifindex_of("eth0")?
      let c = linux.net_constants()
      let ip = open_packet_socket(c.ETH_P_IP, index)?
      let arp = open_packet_socket(c.ETH_P_ARP, index)?
      let everything = open_packet_socket(c.ETH_P_ALL, index)?
      let anywhere = open_packet_socket(c.ETH_P_ARP, 0)?
      probe("first", "192.0.2.1")?
      drain_packets("ip", ip)?
      drain_packets("arp", arp)?
      drain_packets("everything", everything)?
      drain_packets("anywhere", anywhere)?
      var mac = b""
      for link in linux.network_dump()?.links { if link.name == "eth0" { mac = link.address ?? b"" } }
      let broadcast = b"\xff\xff\xff\xff\xff\xff"
      let _ = linux.sendto(arp, arp_request(mac, [192, 0, 2, 10], [192, 0, 2, 1])?, packet_address(index, c.ETH_P_ARP, broadcast)?)?
      drain_packets("arp_after_send", arp)?
      let _ = linux.sendto(ip, broadcast_udp(mac)?, packet_address(index, c.ETH_P_IP, broadcast)?)?
      drain_packets("ip_after_send", ip)?
      drain_packets("everything_after_send", everything)?
      drain_packets("anywhere_after_send", anywhere)?
      step("down", "eth0", false, 2)?
      drain_packets("ip_after_down", ip)?
      drain_packets("anywhere_after_down", anywhere)?
      step("up_again", "eth0", true, 6)?
      probe("second", "192.0.2.1")?
      drain_packets("ip_after_up", ip)?
      drain_packets("anywhere_after_up", anywhere)?
      for socket in [ip, arp, everything, anywhere] { let _ = unix.close_fd(socket) }
    }
    "ioctl-config" => {
      let c = linux.net_constants()
      step("up", "eth0", true, 6)?
      let fd = linux.socket(c.AF_INET, c.SOCK_DGRAM)?
      defer unix.close_fd(fd)
      report("start", "eth0", false)?
      address_ioctl("addr_set", fd, c.SIOCSIFADDR, "eth0", c.AF_INET, [192, 0, 2, 10])
      report("addr_set", "eth0", false)?
      address_ioctl("addr_same", fd, c.SIOCSIFADDR, "eth0", c.AF_INET, [192, 0, 2, 10])
      report("addr_same", "eth0", false)?
      address_ioctl("mask_same", fd, c.SIOCSIFNETMASK, "eth0", c.AF_INET, [255, 255, 255, 0])
      report("mask_same", "eth0", false)?
      address_ioctl("mask_wide", fd, c.SIOCSIFNETMASK, "eth0", c.AF_INET, [255, 255, 0, 0])
      report("mask_wide", "eth0", false)?
      address_ioctl("mask_restore", fd, c.SIOCSIFNETMASK, "eth0", c.AF_INET, [255, 255, 255, 0])
      report("mask_restore", "eth0", false)?
      address_ioctl("mask_bad", fd, c.SIOCSIFNETMASK, "eth0", c.AF_INET, [255, 0, 255, 0])
      address_ioctl("addr_missing", fd, c.SIOCSIFADDR, "missing0", c.AF_INET, [192, 0, 2, 11])
      address_ioctl("mask_missing", fd, c.SIOCSIFNETMASK, "missing0", c.AF_INET, [255, 255, 255, 0])
      address_ioctl("addr_family", fd, c.SIOCSIFADDR, "eth0", c.AF_INET6, [192, 0, 2, 12])
      address_ioctl("mask_family", fd, c.SIOCSIFNETMASK, "eth0", c.AF_INET6, [255, 255, 255, 0])
      report("after_address_errors", "eth0", false)?
      route_ioctl("route_add_default", "add", "0.0.0.0", "0.0.0.0", "192.0.2.1", "eth0")
      report("route_add_default", "eth0", false)?
      route_ioctl("route_add_default_again", "add", "0.0.0.0", "0.0.0.0", "192.0.2.1", "eth0")
      route_ioctl("route_add_network", "add", "10.20.0.0", "255.255.0.0", "-", "eth0")
      report("route_add_network", "eth0", false)?
      route_ioctl("route_add_network_again", "add", "10.20.0.0", "255.255.0.0", "-", "eth0")
      route_ioctl("route_add_bad_mask", "add-bad-mask", "10.0.0.0", "255.255.0.0", "192.0.2.1", "eth0")
      route_ioctl("route_add_family", "add-family", "10.40.0.0", "255.255.0.0", "192.0.2.1", "eth0")
      route_ioctl("route_add_missing_device", "add", "10.30.0.0", "255.255.0.0", "192.0.2.1", "missing0")
      route_ioctl("route_del_network", "del", "10.20.0.0", "255.255.0.0", "-", "eth0")
      route_ioctl("route_del_network_again", "del", "10.20.0.0", "255.255.0.0", "-", "eth0")
      route_ioctl("route_del_default", "del", "0.0.0.0", "0.0.0.0", "192.0.2.1", "eth0")
      route_ioctl("route_del_default_again", "del", "0.0.0.0", "0.0.0.0", "192.0.2.1", "eth0")
      report("final", "eth0", false)?
    }
    other => fail f"unknown network-state mode {other}"
  }
  eprint --flush "NET_DONE"
}
main()
