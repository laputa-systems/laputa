##! Pure IPv4 request encoding and fail-closed read-only virtual-interface projection.
use network_plan as policy

## One encoded route-netlink request for a validated plan operation.
export type NetworkKernelRequest = {message_type: Int, flags: Int, payload: Bytes}
## Rejected observation, stale precondition, or unsupported mutation input.
export error NetworkKernelError = Conflict(message: Str)

pure ordered(snapshot: policy.NetworkSnapshot) -> policy.NetworkSnapshot {
  {...snapshot, addresses: snapshot.addresses |> sort-by .local, routes: snapshot.routes |> sort-by .metric}
}

type NetworkSubnet = {network: Bytes, broadcast: Bytes}

pure subnet(address: policy.NetworkAddress) -> Result[NetworkSubnet, Error] {
  let octets = ipv4_bytes(address.local)?
  var network: List[Int] = []
  var broadcast: List[Int] = []
  var remaining = address.prefix
  for octet in octets {
    let bits = if remaining > 8 { 8 } else { remaining }
    var span = 256
    repeat bits times { span /= 2 }
    let base = octet / span * span
    network += [base]
    broadcast += [base + span - 1]
    remaining -= bits
  }
  Ok({network: bytes.from_ints(network)?, broadcast: bytes.from_ints(broadcast)?})
}

pure address_derived_route(route: LinuxNetworkRoute, address: LinuxNetworkAddress, ifindex: Int) -> Result[Bool, Error] {
  if route.flags != 0 or route.source != null or route.protocol != 2 or route.output_ifindex != ifindex or route.gateway != null or !route.nexthops.is_empty() or route.source_prefix_length != 0 or route.input_ifindex != null or (route.priority != null and route.priority != 0) or address.local == null or route.destination == null or address.prefix_length < 1 or address.prefix_length > 32 {
    return Ok(false)
  }
  if route.attributes.len() != 4 { return Ok(false) }
  var seen: List[Int] = []
  for item in route.attributes {
    if item.kind in seen { return Ok(false) }
    seen += [item.kind]
    match item.kind {
      1 => { if item.data != ipv4_bytes(route.destination)? { return Ok(false) } }
      4 => { if item.data != bytes.pack_le(ifindex, 4)? { return Ok(false) } }
      7 => { if item.data != ipv4_bytes(address.local)? { return Ok(false) } }
      15 => { if item.data != bytes.pack_le(route.table, 4)? { return Ok(false) } }
      else => return Ok(false)
    }
  }
  if route.table == 255 and route.route_type == 2 and route.scope == 254 and route.destination_prefix_length == 32 and route.destination == address.local {
    return Ok(true)
  }
  let expected = subnet({local: address.local, prefix: address.prefix_length})?
  let destination = ipv4_bytes(route.destination)?
  if route.table == 254 and route.route_type == 1 and route.scope == 253 and route.destination_prefix_length == address.prefix_length and destination == expected.network {
    return Ok(true)
  }
  if route.table == 255 and route.route_type == 3 and route.scope == 253 and route.destination_prefix_length == 32 {
    return Ok(destination == expected.network or destination == expected.broadcast or route.destination == address.broadcast)
  }
  Ok(false)
}

pure selected_default_route(route: LinuxNetworkRoute, ifindex: Int) -> Result[policy.NetworkDefaultRoute, Error] {
  if route.tos != 0 {
    return Err(NetworkKernelError.Conflict("selected default route is TOS-specific and cannot converge with ordinary traffic"))
  }
  if route.table != 254 or route.route_type != 1 or route.scope != 0 or route.protocol != 3 or route.flags != 0 or route.gateway == null or route.destination != null or route.source != null or route.preferred_source != null or route.source_prefix_length != 0 or route.input_ifindex != null or !route.nexthops.is_empty() {
    return Err(NetworkKernelError.Conflict("selected default route is outside the supported main-table unicast cohort"))
  }
  let metric = if route.priority == null { 0 } else { route.priority }
  var seen: List[Int] = []
  for item in route.attributes {
    if item.kind in seen { return Err(NetworkKernelError.Conflict("selected default route repeats an attribute")) }
    seen += [item.kind]
    let supported = match item.kind {
      4 => item.data == bytes.pack_le(ifindex, 4)?
      5 => item.data == ipv4_bytes(route.gateway)?
      6 => item.data == bytes.pack_le(metric, 4)?
      15 => item.data == bytes.pack_le(254, 4)?
      else => false
    }
    if !supported { return Err(NetworkKernelError.Conflict("selected default route carries unsupported attributes")) }
  }
  Ok({gateway: route.gateway, metric})
}

## Project a complete dump without silently accepting unsupported selected resources.
export pure network_project_dump(dump: LinuxNetworkDump, intent: policy.NetworkIntent, sequence: Int) -> Result[policy.NetworkSnapshot, Error] {
  if !dump.enumeration_succeeded or dump.state != "complete" or !dump.issues.is_empty() {
    return Err(NetworkKernelError.Conflict("complete issue-free network observation required"))
  }
  let links = [link for link in dump.links if link.ifindex == intent.ifindex or link.name == intent.name]
  if links.len() != 1 { return Err(NetworkKernelError.Conflict("managed link identity is absent or ambiguous")) }
  let link = links[0]
  if link.ifindex != intent.ifindex or link.name != intent.name or link.hardware_type != 1 or (link.kind != "veth" and link.kind != "dummy") or link.master_ifindex != null or link.kind == null {
    return Err(NetworkKernelError.Conflict("managed link is not the selected independent virtual Ethernet interface"))
  }
  var addresses: List[policy.NetworkAddress] = []
  for address in dump.addresses {
    continue when address.ifindex != intent.ifindex or address.family != "inet"
    if address.local == null or address.local != address.address or address.scope != 0 {
      return Err(NetworkKernelError.Conflict("selected IPv4 address is outside the global unicast cohort"))
    }
    if address.flags.bit_and(1) != 0 {
      return Err(NetworkKernelError.Conflict("selected secondary IPv4 addresses require explicit promotion policy"))
    }
    addresses += [{local: address.local, prefix: address.prefix_length}]
  }
  var routes: List[policy.NetworkDefaultRoute] = []
  for route in dump.routes {
    continue when route.family != "inet"
    if route.preferred_source != null {
      for address in dump.addresses {
        continue when address.family != "inet" or address.ifindex != intent.ifindex or address.local != route.preferred_source
        if !address_derived_route(route, address, intent.ifindex)? {
          return Err(NetworkKernelError.Conflict("foreign preferred-source route depends on a selected IPv4 address"))
        }
      }
    }
    continue when route.destination_prefix_length != 0
    for hop in route.nexthops {
      if hop.ifindex == intent.ifindex { return Err(NetworkKernelError.Conflict("selected default route is outside the supported main-table unicast cohort")) }
    }
    continue when route.output_ifindex != intent.ifindex
    routes += [selected_default_route(route, intent.ifindex)?]
  }
  let projected: policy.NetworkSnapshot = {
    sequence, ifindex: link.ifindex, name: intent.name, kind: link.kind,
    up: link.flags.bit_and(1) != 0, addresses, routes,
  }
  Ok(ordered(projected))
}

## Project only when two consecutive complete dumps are identical, since one observation spans four separate kernel dumps.
export pure network_project_stable_dumps(first: LinuxNetworkDump, second: LinuxNetworkDump, intent: policy.NetworkIntent, sequence: Int) -> Result[policy.NetworkSnapshot, Error] {
  let snapshot = network_project_dump(first, intent, sequence)?
  let _ = network_project_dump(second, intent, sequence)?
  if first != second { return Err(NetworkKernelError.Conflict("network observation changed between consecutive dumps")) }
  Ok(snapshot)
}

pure attribute(kind: Int, data: Bytes) -> Result[Bytes, Error] {
  let length = data.len() + 4
  Ok(bytes.concat([bytes.pack_le(length, 2)?, bytes.pack_le(kind, 2)?, data, bytes.zero((4 - length % 4) % 4)?]))
}

pure ipv4_bytes(address: Str) -> Result[Bytes, Error] {
  bytes.from_ints([octet as Int for octet in address.split(".")])
}

## Encode only an operation belonging to a valid, unchanged policy plan.
export pure network_encode_operation(plan: policy.NetworkPlan, index: Int) -> Result[NetworkKernelRequest, Error] {
  let expected = policy.network_plan(plan.intent, plan.owned, plan.before)?
  if expected != plan or index < 0 or index >= plan.operations.len() {
    return Err(NetworkKernelError.Conflict("operation is not part of a valid policy plan"))
  }
  var predicted = plan.before
  for operation in plan.operations {
    match operation {
      policy.NetworkAddAddress(address) => {
        let requested = subnet(address)?
        for existing in predicted.addresses {
          if existing.prefix == address.prefix {
            let current_subnet = subnet(existing)?
            if current_subnet.network == requested.network {
              return Err(NetworkKernelError.Conflict("same-prefix IPv4 additions require explicit promotion policy"))
            }
          }
        }
      }
      policy.NetworkBringLinkUp | policy.NetworkRemoveAddress(_) | policy.NetworkAddDefaultRoute(_) | policy.NetworkRemoveDefaultRoute(_) => {}
    }
    predicted = after_operation(predicted, operation)
  }
  let c = linux.net_constants()
  let request_flags = c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK)
  match plan.operations[index] {
    policy.NetworkBringLinkUp => {
      let payload = bytes.concat([bytes.zero(4)?, bytes.pack_le(plan.intent.ifindex, 4)?, bytes.pack_le(c.IFF_UP, 4)?, bytes.pack_le(c.IFF_UP, 4)?])
      Ok({message_type: c.RTM_NEWLINK, flags: request_flags, payload})
    }
    policy.NetworkAddAddress(address) | policy.NetworkRemoveAddress(address) => {
      let add = plan.operations[index] == policy.NetworkAddAddress(address)
      let header = bytes.concat([bytes.from_ints([c.AF_INET, address.prefix, 0, 0])?, bytes.pack_le(plan.intent.ifindex, 4)?])
      let raw = ipv4_bytes(address.local)?
      let payload = bytes.concat([header, attribute(1, raw)?, attribute(2, raw)?])
      Ok({message_type: if add { c.RTM_NEWADDR } else { c.RTM_DELADDR }, flags: if add { request_flags.bit_or(c.NLM_F_CREATE).bit_or(c.NLM_F_EXCL) } else { request_flags }, payload})
    }
    policy.NetworkAddDefaultRoute(route) | policy.NetworkRemoveDefaultRoute(route) => {
      let add = plan.operations[index] == policy.NetworkAddDefaultRoute(route)
      let header = bytes.concat([bytes.from_ints([c.AF_INET, 0, 0, 0, 254, if add { 3 } else { 0 }, 0, 1])?, bytes.zero(4)?])
      let payload = bytes.concat([header, attribute(4, bytes.pack_le(plan.intent.ifindex, 4)?)?, attribute(5, ipv4_bytes(route.gateway)?)?, attribute(6, bytes.pack_le(route.metric, 4)?)?])
      Ok({message_type: if add { c.RTM_NEWROUTE } else { c.RTM_DELROUTE }, flags: if add { request_flags.bit_or(c.NLM_F_CREATE).bit_or(c.NLM_F_EXCL) } else { request_flags }, payload})
    }
  }
}

pure after_operation(before: policy.NetworkSnapshot, operation: policy.NetworkOperation) -> policy.NetworkSnapshot {
  var next = before
  match operation {
    policy.NetworkBringLinkUp => next.up = true
    policy.NetworkAddAddress(address) => next.addresses += [address]
    policy.NetworkRemoveAddress(address) => next.addresses = [item for item in next.addresses if item != address]
    policy.NetworkAddDefaultRoute(route) => next.routes += [route]
    policy.NetworkRemoveDefaultRoute(route) => next.routes = [item for item in next.routes if item != route]
  }
  ordered(next)
}
