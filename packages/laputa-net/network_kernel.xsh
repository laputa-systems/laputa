##! Fail-closed virtual-interface projection from typed network state and the mapping of plan operations onto typed changes, for IPv4 and IPv6.
use network_plan as policy
use lib.net_state

const IFA_F_NODAD = 2
const IFA_F_OPTIMISTIC = 4
const IFA_F_DADFAILED = 8
const IFA_F_DEPRECATED = 32
const IFA_F_TENTATIVE = 64
const IFA_F_PERMANENT = 128
const IFA_F_IPV6_COHORT = 238
const RT_SCOPE_LINK = 253
const RTPROT_RA = 9
const IPV6_KERNEL_ROUTE_ATTRIBUTES = [12, 20]

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

pure selected_default_route(route: net_state.Route, family: net_state.Family) -> Result[policy.NetworkDefaultRoute, Error] {
  if route.tos != 0 {
    return Err(NetworkKernelError.Conflict("selected default route is TOS-specific and cannot converge with ordinary traffic"))
  }
  let gateway = route.hops[0].gateway
  if route.table != net_state.TABLE_MAIN or route.route_type != 1 or route.scope != 0 or route.protocol != 3 or route.flags != 0 or gateway == null or route.destination != null or route.source != null or route.preferred_source != null or route.source_prefix != 0 {
    return Err(NetworkKernelError.Conflict("selected default route is outside the supported main-table unicast cohort"))
  }
  let unmodeled = [kind for kind in route.other_attributes if family == .Inet or kind not in IPV6_KERNEL_ROUTE_ATTRIBUTES]
  if !unmodeled.is_empty() {
    return Err(NetworkKernelError.Conflict("selected default route carries unsupported attributes"))
  }
  Ok({gateway, metric: route.priority})
}

pure intent_family(intent: policy.NetworkIntent) -> net_state.Family {
  if policy.network_is_ipv6(intent.address.local) { .Inet6 } else { .Inet }
}

pure family_name(family: net_state.Family) -> Str {
  if family == .Inet6 { "IPv6" } else { "IPv4" }
}

pure project_inet6_addresses(selected: List[net_state.Address]) -> Result[List[net_state.Address], Error] {
  var cohort: List[net_state.Address] = []
  for address in selected {
    continue when address.scope == RT_SCOPE_LINK
    continue when address.flags.bit_and(IFA_F_PERMANENT) == 0
    if address.peer != null or address.scope != 0 {
      return Err(NetworkKernelError.Conflict("selected IPv6 address is outside the global unicast cohort"))
    }
    if address.flags.bit_and(IFA_F_DADFAILED) != 0 {
      return Err(NetworkKernelError.Conflict("selected IPv6 address failed duplicate address detection"))
    }
    if address.flags != address.flags.bit_and(IFA_F_IPV6_COHORT) {
      return Err(NetworkKernelError.Conflict("selected IPv6 address carries flags that require explicit policy"))
    }
    cohort += [address]
  }
  Ok(cohort)
}

## Project a typed observation without silently accepting unsupported selected resources.
export pure network_project_state(state: net_state.State, intent: policy.NetworkIntent, sequence: Int) -> Result[policy.NetworkSnapshot, Error] {
  let links = [link for link in state.links if link.ifindex == intent.ifindex or link.name == intent.name]
  if links.len() != 1 { return Err(NetworkKernelError.Conflict("managed link identity is absent or ambiguous")) }
  let link = links[0]
  if link.ifindex != intent.ifindex or link.name != intent.name or link.hardware_type != 1 or (link.kind != "veth" and link.kind != "dummy") or link.master_ifindex != null or link.kind == null {
    return Err(NetworkKernelError.Conflict("managed link is not the selected independent virtual Ethernet interface"))
  }
  let family = intent_family(intent)
  let on_link = [address for address in net_state.addresses_of(state, intent.ifindex) if address.family == family]
  var selected: List[net_state.Address] = []
  if family == .Inet6 {
    selected = project_inet6_addresses(on_link)?
  } else {
    selected = on_link
  }
  var addresses: List[policy.NetworkAddress] = []
  for address in selected {
    if family == .Inet {
      if address.peer != null or address.scope != 0 {
        return Err(NetworkKernelError.Conflict("selected IPv4 address is outside the global unicast cohort"))
      }
      if address.flags.bit_and(1) != 0 {
        return Err(NetworkKernelError.Conflict("selected secondary IPv4 addresses require explicit promotion policy"))
      }
    }
    addresses += [{local: address.local, prefix: address.prefix}]
  }
  var routes: List[policy.NetworkDefaultRoute] = []
  for route in state.routes {
    continue when route.family != family
    if route.preferred_source != null {
      for address in selected {
        continue when address.local != route.preferred_source
        if family == .Inet6 {
          return Err(NetworkKernelError.Conflict("foreign preferred-source route depends on a selected IPv6 address"))
        }
        if !address_derived_route(route, address, intent.ifindex)? {
          return Err(NetworkKernelError.Conflict("foreign preferred-source route depends on a selected IPv4 address"))
        }
      }
    }
    continue when route.prefix != 0
    let hops_on_link = [hop for hop in route.hops if hop.ifindex == intent.ifindex]
    continue when hops_on_link.is_empty()
    continue when family == .Inet6 and route.protocol == RTPROT_RA
    if route.hops.len() != 1 { return Err(NetworkKernelError.Conflict("selected default route is outside the supported main-table unicast cohort")) }
    routes += [selected_default_route(route, family)?]
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

pure change_for(operation: policy.NetworkOperation, ifindex: Int) -> Result[net_state.Change, Error] {
  match operation {
    policy.NetworkBringLinkUp => Ok(net_state.LinkUp(ifindex))
    policy.NetworkAddAddress(address) => Ok(net_state.AddAddress(typed_address(address, ifindex)))
    policy.NetworkRemoveAddress(address) => Ok(net_state.RemoveAddress(typed_address(address, ifindex)))
    policy.NetworkAddDefaultRoute(route) => {
      if route.metric == 0 {
        return Err(NetworkKernelError.Conflict("a zero-metric default route is never created because the kernel treats priority 0 as unset on removal, so it could not be removed exactly"))
      }
      Ok(net_state.AddRoute(typed_default_route(route, ifindex)))
    }
    policy.NetworkRemoveDefaultRoute(route) => {
      if route.metric == 0 {
        return Err(NetworkKernelError.Conflict("a zero-metric default route cannot be removed exactly; the kernel treats a zero priority as a wildcard over every metric"))
      }
      Ok(net_state.RemoveRoute(typed_default_route(route, ifindex)))
    }
  }
}

pure validated_plan(plan: policy.NetworkPlan) -> Result[Unit, Error] {
  let expected = policy.network_plan(plan.intent, plan.owned, plan.before)?
  if expected != plan {
    return Err(NetworkKernelError.Conflict("operation is not part of a valid policy plan"))
  }
  var predicted = plan.before
  for operation in plan.operations {
    match operation {
      policy.NetworkAddAddress(address) => {
        if !policy.network_is_ipv6(address.local) {
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
      }
      policy.NetworkBringLinkUp | policy.NetworkRemoveAddress(_) | policy.NetworkAddDefaultRoute(_) | policy.NetworkRemoveDefaultRoute(_) => {}
    }
    predicted = after_operation(predicted, operation)
  }
  Ok()
}

## Every change of a valid, unchanged policy plan, in plan order, before any
## effect. One unencodable removal refuses the whole plan, so no operation of a
## plan that cannot finish exactly is ever applied.
export pure network_changes(plan: policy.NetworkPlan) -> Result[List[net_state.Change], Error] {
  validated_plan(plan)
  Ok([change_for(operation, plan.intent.ifindex)? for operation in plan.operations])
}

## Map one operation belonging to a valid, unchanged policy plan onto a typed
## change. The plan's own validity, including same-prefix ambiguity, is checked
## for every operation; encodability is refused only for this operation, so the
## whole set `network_changes` additionally refuses when a later one cannot be
## expressed.
export pure network_change(plan: policy.NetworkPlan, index: Int) -> Result[net_state.Change, Error] {
  validated_plan(plan)?
  if index < 0 or index >= plan.operations.len() {
    return Err(NetworkKernelError.Conflict("operation is not part of a valid policy plan"))
  }
  change_for(plan.operations[index], plan.intent.ifindex)
}

## The observation a plan's first `count` operations must produce from its precondition.
export pure network_after(plan: policy.NetworkPlan, count: Int) -> Result[policy.NetworkSnapshot, Error] {
  let expected = policy.network_plan(plan.intent, plan.owned, plan.before)?
  if expected != plan or count < 0 or count > plan.operations.len() {
    return Err(NetworkKernelError.Conflict("operation is not part of a valid policy plan"))
  }
  var predicted = plan.before
  for operation in plan.operations[0..count] {
    predicted = after_operation(predicted, operation)
  }
  Ok(predicted)
}

pure text_family(text: Str) -> net_state.Family {
  if policy.network_is_ipv6(text) { .Inet6 } else { .Inet }
}

pure typed_address(address: policy.NetworkAddress, ifindex: Int) -> net_state.Address {
  {ifindex, family: text_family(address.local), local: address.local, prefix: address.prefix, peer: null, broadcast: null, scope: 0, flags: 0}
}

pure typed_default_route(route: policy.NetworkDefaultRoute, ifindex: Int) -> net_state.Route {
  {
    family: text_family(route.gateway), table: net_state.TABLE_MAIN, destination: null, prefix: 0,
    source: null, source_prefix: 0, preferred_source: null, tos: 0, priority: route.metric,
    protocol: 3, scope: 0, route_type: 1, flags: 0,
    hops: [{ifindex, gateway: route.gateway}], other_attributes: [],
  }
}

## One live reconcile pass: the plan it applied, how many changes it attempted,
## the observation it last trusted, its ordered replay events, and the verdict.
## A conflict is a reported re-observation; nothing is rolled back or replayed.
export type NetworkReconcile = {
  plan: policy.NetworkPlan,
  attempts: Int,
  observed: policy.NetworkSnapshot?,
  events: List[policy.NetworkReplayEvent],
  result: policy.NetworkReplayResult,
}

## True when two observations name the same cohort, whatever their ordinals.
export pure same_cohort(left: policy.NetworkSnapshot, right: policy.NetworkSnapshot) -> Bool {
  left.ifindex == right.ifindex and left.name == right.name and left.kind == right.kind and left.up == right.up and left.addresses == right.addresses and left.routes == right.routes
}

## Observe and project the managed link, reporting an untrustworthy observation
## as its own failure rather than an empty state.
export proc network_observe(intent: policy.NetworkIntent, sequence: Int) [process, env, error] -> Result[policy.NetworkSnapshot, Error] {
  network_project_state(net_state.observe()?, intent, sequence)
}

## Apply a planned change set through `net_state.apply`, re-observing before and
## after every step. A stale precondition, refused operation, transport failure,
## untrustworthy observation or lost notification stops the pass with an explicit
## re-observation; no change is retried or reverted, and a refused change never
## implies a rollback.
export proc network_apply_plan(plan: policy.NetworkPlan, notifications: Int, sequence: Int) [process, env, net, error] -> Result[NetworkReconcile, Error] {
  let changes = network_changes(plan)?
  var events: List[policy.NetworkReplayEvent] = [policy.NetworkPrecondition(plan.before)]
  var attempts = 0
  var ordinal = sequence
  if let lost = network_lost_events(net_state.drain(notifications)?) {
    return Ok({plan, attempts, observed: null, events: events + [lost], result: policy.NetworkReobserve("lost events require full observation")})
  }
  var final = plan.before
  for index in range(changes.len()) {
    ordinal += 1
    var precondition = plan.before
    match network_observe(plan.intent, ordinal) {
      Ok(observed) => { precondition = observed }
      Err(problem) => return Ok({plan, attempts, observed: null, events, result: policy.NetworkReobserve(f"observing before operation {index} failed: {problem.message}")})
    }
    if !same_cohort(precondition, network_after(plan, index)?) {
      return Ok({plan, attempts, observed: precondition, events, result: policy.NetworkReobserve(f"observation changed before operation {index}")})
    }
    attempts += 1
    let outcome = network_outcome(index, net_state.apply(changes[index]))
    events += [outcome]
    ordinal += 1
    if let lost = network_lost_events(net_state.drain(notifications)?) {
      return Ok({plan, attempts, observed: null, events: events + [lost], result: policy.NetworkReobserve("lost events require full observation")})
    }
    var observed = plan.before
    match network_observe(plan.intent, ordinal) {
      Ok(reobserved) => { observed = reobserved }
      Err(problem) => return Ok({plan, attempts, observed: null, events, result: policy.NetworkReobserve(f"observing after operation {index} failed: {problem.message}")})
    }
    final = observed
    if outcome != policy.NetworkApplied(index) {
      return Ok({plan, attempts, observed, events: events + [policy.NetworkObserved(observed)], result: policy.network_replay(plan, events)})
    }
    if !same_cohort(observed, network_after(plan, index + 1)?) {
      return Ok({plan, attempts, observed, events: events + [policy.NetworkObserved(observed)], result: policy.NetworkReobserve(f"operation {index} was acknowledged but the observation diverged")})
    }
  }
  if changes.is_empty() {
    ordinal += 1
    match network_observe(plan.intent, ordinal) {
      Ok(reobserved) => { final = reobserved }
      Err(problem) => return Ok({plan, attempts, observed: null, events, result: policy.NetworkReobserve(f"re-observing an unchanged plan failed: {problem.message}")})
    }
  }
  events += [policy.NetworkObserved(final)]
  Ok({plan, attempts, observed: final, events, result: policy.network_replay(plan, events)})
}

## Observe, plan and reconcile one managed link over one notification stream.
## A plan with no changes attempts no mutation and still re-observes.
export proc network_reconcile(intent: policy.NetworkIntent, owned: policy.NetworkOwnership, sequence: Int) [process, env, net, error] -> Result[NetworkReconcile, Error] {
  let notifications = net_state.subscribe()?
  defer unix.close_fd(notifications)
  let observed = network_observe(intent, sequence)?
  let plan = policy.network_plan(intent, owned, observed)?
  network_apply_plan(plan, notifications, sequence)
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
