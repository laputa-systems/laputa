##! Fail-closed virtual-interface projection from typed network state and the mapping of plan operations onto typed changes.
use network_plan as policy
use lib.net_state

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
    for _ in range(bits) { span /= 2 }
    let base = octet / span * span
    network += [base]
    broadcast += [base + span - 1]
    remaining -= bits
  }
  Ok({network: bytes.from_ints(network)?, broadcast: bytes.from_ints(broadcast)?})
}

pure address_derived_route(route: net_state.Route, address: net_state.Address, ifindex: Int) -> Result[Bool, Error] {
  if route.flags != 0 or route.source != null or route.protocol != 2 or route.hops.len() != 1 or route.hops[0].ifindex != ifindex or route.hops[0].gateway != null or route.source_prefix != 0 or route.priority != 0 or route.destination == null or address.prefix < 1 or address.prefix > 32 or !route.other_attributes.is_empty() {
    return Ok(false)
  }
  if route.table == 255 and route.route_type == 2 and route.scope == 254 and route.prefix == 32 and route.destination == address.local {
    return Ok(true)
  }
  let expected = subnet({local: address.local, prefix: address.prefix})?
  let destination = ipv4_bytes(route.destination)?
  if route.table == 254 and route.route_type == 1 and route.scope == 253 and route.prefix == address.prefix and destination == expected.network {
    return Ok(true)
  }
  if route.table == 255 and route.route_type == 3 and route.scope == 253 and route.prefix == 32 {
    return Ok(destination == expected.network or destination == expected.broadcast or route.destination == address.broadcast)
  }
  Ok(false)
}

pure selected_default_route(route: net_state.Route) -> Result[policy.NetworkDefaultRoute, Error] {
  if route.tos != 0 {
    return Err(NetworkKernelError.Conflict("selected default route is TOS-specific and cannot converge with ordinary traffic"))
  }
  let gateway = route.hops[0].gateway
  if route.table != net_state.TABLE_MAIN or route.route_type != 1 or route.scope != 0 or route.protocol != 3 or route.flags != 0 or gateway == null or route.destination != null or route.source != null or route.preferred_source != null or route.source_prefix != 0 {
    return Err(NetworkKernelError.Conflict("selected default route is outside the supported main-table unicast cohort"))
  }
  if !route.other_attributes.is_empty() {
    return Err(NetworkKernelError.Conflict("selected default route carries unsupported attributes"))
  }
  Ok({gateway, metric: route.priority})
}

## Project a typed observation without silently accepting unsupported selected resources.
export pure network_project_state(state: net_state.State, intent: policy.NetworkIntent, sequence: Int) -> Result[policy.NetworkSnapshot, Error] {
  let links = [link for link in state.links if link.ifindex == intent.ifindex or link.name == intent.name]
  if links.len() != 1 { return Err(NetworkKernelError.Conflict("managed link identity is absent or ambiguous")) }
  let link = links[0]
  if link.ifindex != intent.ifindex or link.name != intent.name or link.hardware_type != 1 or (link.kind != "veth" and link.kind != "dummy") or link.master_ifindex != null or link.kind == null {
    return Err(NetworkKernelError.Conflict("managed link is not the selected independent virtual Ethernet interface"))
  }
  let selected = [address for address in net_state.addresses_of(state, intent.ifindex) if address.family == .Inet]
  var addresses: List[policy.NetworkAddress] = []
  for address in selected {
    if address.peer != null or address.scope != 0 {
      return Err(NetworkKernelError.Conflict("selected IPv4 address is outside the global unicast cohort"))
    }
    if address.flags.bit_and(1) != 0 {
      return Err(NetworkKernelError.Conflict("selected secondary IPv4 addresses require explicit promotion policy"))
    }
    addresses += [{local: address.local, prefix: address.prefix}]
  }
  var routes: List[policy.NetworkDefaultRoute] = []
  for route in state.routes {
    continue when route.family != .Inet
    if route.preferred_source != null {
      for address in selected {
        continue when address.local != route.preferred_source
        if !address_derived_route(route, address, intent.ifindex)? {
          return Err(NetworkKernelError.Conflict("foreign preferred-source route depends on a selected IPv4 address"))
        }
      }
    }
    continue when route.prefix != 0
    let on_link = [hop for hop in route.hops if hop.ifindex == intent.ifindex]
    continue when on_link.is_empty()
    if route.hops.len() != 1 { return Err(NetworkKernelError.Conflict("selected default route is outside the supported main-table unicast cohort")) }
    routes += [selected_default_route(route)?]
  }
  let projected: policy.NetworkSnapshot = {
    sequence, ifindex: link.ifindex, name: intent.name, kind: link.kind,
    up: net_state.is_up(link), addresses, routes,
  }
  Ok(ordered(projected))
}

## Project a complete dump; any incomplete, interrupted or undecodable dump is an error, never an empty state.
export pure network_project_dump(dump: LinuxNetworkDump, intent: policy.NetworkIntent, sequence: Int) -> Result[policy.NetworkSnapshot, Error] {
  network_project_state(net_state.project(dump)?, intent, sequence)
}

## Project only when two consecutive observations are identical, since one observation spans four separate kernel dumps.
export pure network_project_stable_states(first: net_state.State, second: net_state.State, intent: policy.NetworkIntent, sequence: Int) -> Result[policy.NetworkSnapshot, Error] {
  let snapshot = network_project_state(first, intent, sequence)?
  let _ = network_project_state(second, intent, sequence)?
  if first != second { return Err(NetworkKernelError.Conflict("network observation changed between consecutive dumps")) }
  Ok(snapshot)
}

pure ipv4_bytes(address: Str) -> Result[Bytes, Error] {
  bytes.from_ints([octet as Int for octet in address.split(".")])
}

## Map only an operation belonging to a valid, unchanged policy plan onto a typed change.
export pure network_change(plan: policy.NetworkPlan, index: Int) -> Result[net_state.Change, Error] {
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
  let ifindex = plan.intent.ifindex
  match plan.operations[index] {
    policy.NetworkBringLinkUp => Ok(net_state.LinkUp(ifindex))
    policy.NetworkAddAddress(address) => Ok(net_state.AddAddress(typed_address(address, ifindex)))
    policy.NetworkRemoveAddress(address) => Ok(net_state.RemoveAddress(typed_address(address, ifindex)))
    policy.NetworkAddDefaultRoute(route) => Ok(net_state.AddRoute(typed_default_route(route, ifindex)))
    policy.NetworkRemoveDefaultRoute(route) => Ok(net_state.RemoveRoute(typed_default_route(route, ifindex)))
  }
}

pure typed_address(address: policy.NetworkAddress, ifindex: Int) -> net_state.Address {
  {ifindex, family: .Inet, local: address.local, prefix: address.prefix, peer: null, broadcast: null, scope: 0, flags: 0}
}

pure typed_default_route(route: policy.NetworkDefaultRoute, ifindex: Int) -> net_state.Route {
  {
    family: .Inet, table: net_state.TABLE_MAIN, destination: null, prefix: 0,
    source: null, source_prefix: 0, preferred_source: null, tos: 0, priority: route.metric,
    protocol: 3, scope: 0, route_type: 1, flags: 0,
    hops: [{ifindex, gateway: route.gateway}], other_attributes: [],
  }
}

## The replay event for the kernel's verdict on one operation: a refusal is a denial; anything else that did not apply is a failure.
export pure network_outcome(index: Int, result: Result[Unit, net_state.ChangeFailure]) -> policy.NetworkReplayEvent {
  match result {
    Ok(_) => policy.NetworkApplied(index)
    Err(net_state.ChangeFailure.Refused {..}) => policy.NetworkDenied(index)
    Err(_) => policy.NetworkFailed(index)
  }
}

## The replay event for drained notifications that say the last observation can no longer be trusted, if any.
export pure network_lost_events(notices: net_state.Notices) -> policy.NetworkReplayEvent? {
  match notices {
    net_state.Lost(reason) => policy.NetworkLostEvents
    else => null
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
