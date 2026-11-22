##! Ownership-aware offline planning for one virtual Ethernet cohort of one address family, IPv4 or IPv6.
## One canonical IPv4 or global-unicast IPv6 host address and prefix, in the text the kernel reports.
export type NetworkAddress = {local: Str, prefix: Int}
## One main-table unicast default route on the managed link.
export type NetworkDefaultRoute = {gateway: Str, metric: Int}
## Desired state for an explicitly selected virtual Ethernet link. The address
## selects the family; the gateway must belong to it. A zero metric selects the
## kernel's default for IPv6 (1024), which a zero IPv6 metric cannot express exactly.
export type NetworkIntent = {ifindex: Int, name: Str, address: NetworkAddress, gateway: Str, metric: Int}
## Explicit authority over exact resources on one link; observation never grants ownership.
export type NetworkOwnership = {ifindex: Int, name: Str, addresses: List[NetworkAddress], routes: List[NetworkDefaultRoute]}
## Complete bounded cohort of the intent's address family; sequence is a caller-owned observation ordinal.
export type NetworkSnapshot = {
  sequence: Int, ifindex: Int, name: Str, kind: Str, up: Bool,
  addresses: List[NetworkAddress], routes: List[NetworkDefaultRoute],
}
## Ordered requested changes; no operation flushes or replaces foreign state.
export enum NetworkOperation {
  NetworkBringLinkUp,
  NetworkAddAddress(NetworkAddress),
  NetworkRemoveAddress(NetworkAddress),
  NetworkAddDefaultRoute(NetworkDefaultRoute),
  NetworkRemoveDefaultRoute(NetworkDefaultRoute),
}
## Inspectably binds operations to their intent, ownership and exact precondition.
export type NetworkPlan = {
  intent: NetworkIntent, owned: NetworkOwnership, before: NetworkSnapshot,
  operations: List[NetworkOperation],
}
## Offline plan input; a trusted complete observation must be supplied explicitly.
export type NetworkPlanInput = {intent: NetworkIntent, owned: NetworkOwnership, observed: NetworkSnapshot}
## Ordered reduced boundary observations and operation outcomes.
export enum NetworkReplayEvent {
  NetworkPrecondition(NetworkSnapshot),
  NetworkApplied(Int),
  NetworkDenied(Int),
  NetworkFailed(Int),
  NetworkObserved(NetworkSnapshot),
  NetworkLostEvents,
  NetworkTruncated,
}
## Convergence requires a fresh final observation; failures require reconciliation.
export enum NetworkReplayResult {
  NetworkConverged(NetworkOwnership),
  NetworkReobserve(Str),
  NetworkInvalid(Str),
}
## Rejected policy input or a rooted read failure retaining its source metadata.
export error NetworkPolicyError = NetworkInvalid(message: Str) | NetworkReadFailed(path: Path, state: Str, errno: Int?, error_kind: Str?, message: Str)

## Maximum encoded network plan or capture size in bytes.
export const network_input_limit = 65536

const network_resource_limit = 64
const network_replay_limit = network_resource_limit * 2 + 5

## Read only the selected input's bounded bytes, rejecting truncation before UTF-8 decoding.
export proc network_read_input(input: Path) [fs, error] -> Result[Str, Error] {
  let selected = input.resolve()?
  let parent = selected.parent
  let root = fs.open_root(parent)?
  let leaf = selected.strip_prefix(parent)?
  let snapshot = root.read_result(leaf, max_bytes: network_input_limit)?
  if snapshot.state != "observed" or snapshot.data == null {
    return Err(NetworkPolicyError.NetworkReadFailed(path: selected, state: snapshot.state, errno: snapshot.errno, error_kind: snapshot.error_kind, message: f"cannot read network input {selected} ({snapshot.state})"))
  }
  if snapshot.truncated {
    return Err(NetworkPolicyError.NetworkInvalid(f"network input exceeds {network_input_limit} bytes"))
  }
  let data: Bytes = snapshot.data
  data.utf8()
}

const ipv6_default_metric = 1024
const hex_digits = "0123456789abcdef"

pure ipv4(value: Str) -> Bool {
  let octets = value.split(".")
  return false when octets.len() != 4
  for octet in octets {
    return false when octet.is_empty() or octet.byte_len() > 3
    return false when octet.byte_len() > 1 and octet.starts_with("0")
    var number = 0
    for digit in octet {
      let position = "0123456789".find(digit)
      return false when position == null
      number = number * 10 + position
    }
    return false when number > 255
  }
  true
}

## True when the text is IPv6 rather than IPv4; any colon selects IPv6.
export pure network_is_ipv6(value: Str) -> Bool {
  value.find(":") != null
}

pure hex_pieces(text: Str) -> List[Int]? {
  return [] when text.is_empty()
  var values: List[Int] = []
  for piece in text.split(":") {
    return null when piece.is_empty() or piece.byte_len() > 4
    var value = 0
    for digit in piece {
      let position = hex_digits.find(digit)
      return null when position == null
      value = value * 16 + position
    }
    values += [value]
  }
  values
}

pure ipv6_groups(value: Str) -> List[Int]? {
  return null when value.byte_len() < 2 or value.byte_len() > 39
  let halves = value.split("::")
  return null when halves.len() > 2
  guard let lead = hex_pieces(halves[0]) else { return null }
  if halves.len() == 1 {
    return null when lead.len() != 8
    return lead
  }
  guard let rest = hex_pieces(halves[1]) else { return null }
  let missing = 8 - lead.len() - rest.len()
  return null when missing < 1
  [@lead, @[0 for _ in range(missing)], @rest]
}

pure hex_text(value: Int) -> Str {
  return "0" when value == 0
  var text = ""
  var rest = value
  while rest > 0 {
    text = hex_digits.byte_slice(rest % 16, length: 1) + text
    rest = rest / 16
  }
  text
}

pure ipv6_render(groups: List[Int]) -> Str {
  var best_start = -1
  var best_length = 1
  var index = 0
  while index < 8 {
    if groups[index] == 0 {
      var end = index
      while end < 8 and groups[end] == 0 { end += 1 }
      if end - index > best_length {
        best_start = index
        best_length = end - index
      }
      index = end
    } else {
      index += 1
    }
  }
  var text = ""
  var position = 0
  while position < 8 {
    if position == best_start {
      text += "::"
      position += best_length
    } else {
      if text != "" and !text.ends_with(":") { text += ":" }
      text += hex_text(groups[position])
      position += 1
    }
  }
  text
}

pure ipv6_unicast(value: Str, link_local: Bool) -> Bool {
  guard let groups = ipv6_groups(value) else { return false }
  return false when ipv6_render(groups) != value
  var leading_zero = true
  for value in groups[0..5] {
    if value != 0 { leading_zero = false }
  }
  return false when leading_zero and (groups[5] == 0 or groups[5] == 65535)
  return false when groups[0] / 256 == 255
  return link_local when groups[0] / 64 == 1018
  true
}

pure valid_address(address: NetworkAddress) -> Bool {
  if network_is_ipv6(address.local) {
    ipv6_unicast(address.local, false) and address.prefix >= 1 and address.prefix <= 128
  } else {
    ipv4(address.local) and address.prefix >= 1 and address.prefix <= 32
  }
}

pure valid_gateway(gateway: Str, ipv6: Bool) -> Bool {
  if ipv6 { network_is_ipv6(gateway) and ipv6_unicast(gateway, true) } else { !network_is_ipv6(gateway) and ipv4(gateway) }
}

pure valid_route(route: NetworkDefaultRoute, ipv6: Bool) -> Bool {
  valid_gateway(route.gateway, ipv6) and route.metric >= 0
}

pure family_name(ipv6: Bool) -> Str {
  if ipv6 { "IPv6" } else { "IPv4" }
}

## The metric the kernel records for the intent's default route: an IPv6 route
## created without a priority is stored with metric 1024, never zero.
export pure network_desired_route(intent: NetworkIntent) -> NetworkDefaultRoute {
  let ipv6 = network_is_ipv6(intent.address.local)
  {gateway: intent.gateway, metric: if ipv6 and intent.metric == 0 { ipv6_default_metric } else { intent.metric }}
}

## Compute changes without effects or inferred resource ownership.
export pure network_plan(intent: NetworkIntent, owned: NetworkOwnership, observed: NetworkSnapshot) -> Result[NetworkPlan, Error] {
  if intent.ifindex <= 0 or intent.name.is_empty() or intent.ifindex != observed.ifindex or intent.name != observed.name {
    return Err(NetworkPolicyError.NetworkInvalid("managed link identity mismatch"))
  }
  if owned.ifindex != intent.ifindex or owned.name != intent.name {
    return Err(NetworkPolicyError.NetworkInvalid("ownership belongs to another link"))
  }
  if observed.kind != "veth" and observed.kind != "dummy" {
    return Err(NetworkPolicyError.NetworkInvalid("only veth and dummy virtual Ethernet links are supported"))
  }
  let ipv6 = network_is_ipv6(intent.address.local)
  let family = family_name(ipv6)
  if observed.sequence < 0 or !valid_address(intent.address) or !valid_gateway(intent.gateway, ipv6) or intent.metric < 0 {
    return Err(NetworkPolicyError.NetworkInvalid(f"invalid {family} intent or observation sequence"))
  }
  if observed.addresses.len() > network_resource_limit or observed.routes.len() > network_resource_limit or owned.addresses.len() > network_resource_limit or owned.routes.len() > network_resource_limit {
    return Err(NetworkPolicyError.NetworkInvalid(f"network cohort exceeds {network_resource_limit} resources per kind"))
  }
  var seen_addresses: List[NetworkAddress] = []
  for address in observed.addresses {
    if network_is_ipv6(address.local) != ipv6 {
      return Err(NetworkPolicyError.NetworkInvalid(f"observed cohort holds an address outside the intent's {family} family"))
    }
    if !valid_address(address) or address in seen_addresses {
      return Err(NetworkPolicyError.NetworkInvalid(f"invalid or duplicate observed {family} address"))
    }
    seen_addresses += [address]
  }
  var seen_routes: List[NetworkDefaultRoute] = []
  for route in observed.routes {
    if network_is_ipv6(route.gateway) != ipv6 {
      return Err(NetworkPolicyError.NetworkInvalid(f"observed cohort holds a default route outside the intent's {family} family"))
    }
    if !valid_route(route, ipv6) or route in seen_routes {
      return Err(NetworkPolicyError.NetworkInvalid("invalid or duplicate observed default route"))
    }
    seen_routes += [route]
  }
  seen_addresses = []
  for address in owned.addresses {
    if network_is_ipv6(address.local) != ipv6 {
      return Err(NetworkPolicyError.NetworkInvalid(f"ownership holds an address outside the intent's {family} family"))
    }
    if !valid_address(address) or address in seen_addresses {
      return Err(NetworkPolicyError.NetworkInvalid(f"invalid or duplicate owned {family} address"))
    }
    seen_addresses += [address]
  }
  seen_routes = []
  for route in owned.routes {
    if network_is_ipv6(route.gateway) != ipv6 {
      return Err(NetworkPolicyError.NetworkInvalid(f"ownership holds a default route outside the intent's {family} family"))
    }
    if !valid_route(route, ipv6) or route in seen_routes {
      return Err(NetworkPolicyError.NetworkInvalid("invalid or duplicate owned default route"))
    }
    seen_routes += [route]
  }
  let desired_route = network_desired_route(intent)
  if intent.address in observed.addresses and intent.address not in owned.addresses {
    return Err(NetworkPolicyError.NetworkInvalid("desired address is foreign; ownership cannot be inferred"))
  }
  if ipv6 {
    for address in observed.addresses {
      if address.local == intent.address.local and address.prefix != intent.address.prefix {
        return Err(NetworkPolicyError.NetworkInvalid("desired IPv6 address is present with another prefix; explicit reconciliation required"))
      }
    }
  }
  if desired_route in observed.routes and desired_route not in owned.routes {
    return Err(NetworkPolicyError.NetworkInvalid("desired route is foreign; ownership cannot be inferred"))
  }
  for route in observed.routes {
    if route.metric == desired_route.metric and route != desired_route {
      return Err(NetworkPolicyError.NetworkInvalid("default route metric is occupied; explicit reconciliation required"))
    }
  }
  var operations: List[NetworkOperation] = []
  if !observed.up { operations += [NetworkBringLinkUp] }
  if intent.address not in observed.addresses { operations += [NetworkAddAddress(intent.address)] }
  if desired_route not in observed.routes { operations += [NetworkAddDefaultRoute(desired_route)] }
  for route in owned.routes {
    if route != desired_route and route in observed.routes { operations += [NetworkRemoveDefaultRoute(route)] }
  }
  for address in owned.addresses {
    if address != intent.address and address in observed.addresses { operations += [NetworkRemoveAddress(address)] }
  }
  Ok({intent, owned, before: observed, operations})
}

## Validate a bounded offline result sequence without consulting the host.
export pure network_replay(plan: NetworkPlan, events: List[NetworkReplayEvent]) -> NetworkReplayResult {
  match network_plan(plan.intent, plan.owned, plan.before) {
    Err(_) => return NetworkInvalid("invalid plan precondition")
    Ok(expected_plan) => {
      if expected_plan != plan { return NetworkInvalid("plan operations do not match policy") }
    }
  }
  if events.len() > network_replay_limit { return NetworkInvalid(f"replay exceeds {network_replay_limit} events") }
  if events.is_empty() { return NetworkInvalid("missing precondition observation") }
  match events[0] {
    NetworkLostEvents => return NetworkReobserve("lost events require full observation")
    NetworkTruncated => return NetworkInvalid("truncated observation")
    NetworkPrecondition(observed) => {
      if observed != plan.before { return NetworkReobserve("stale precondition") }
    }
    NetworkApplied(_) | NetworkDenied(_) | NetworkFailed(_) | NetworkObserved(_) => return NetworkInvalid("expected precondition observation")
  }
  var next_operation = 0
  var converged = false
  let expected: NetworkOwnership = {
    ifindex: plan.intent.ifindex, name: plan.intent.name,
    addresses: [plan.intent.address], routes: [network_desired_route(plan.intent)],
  }
  for event_index, event in events {
    continue when event_index == 0
    if converged { return NetworkInvalid("events after final observation") }
    match event {
      NetworkLostEvents => return NetworkReobserve("lost events require full observation")
      NetworkTruncated => return NetworkInvalid("truncated observation")
      NetworkPrecondition(_) => return NetworkInvalid("repeated precondition observation")
      NetworkApplied(index) => {
        if index != next_operation or index >= plan.operations.len() { return NetworkInvalid("operation result out of order") }
        next_operation += 1
      }
      NetworkDenied(index) => {
        if index != next_operation or index >= plan.operations.len() { return NetworkInvalid("operation result out of order") }
        return NetworkReobserve(f"operation {index} denied; partial state requires observation")
      }
      NetworkFailed(index) => {
        if index != next_operation or index >= plan.operations.len() { return NetworkInvalid("operation result out of order") }
        return NetworkReobserve(f"operation {index} failed; partial state requires observation")
      }
      NetworkObserved(observed) => {
        if next_operation != plan.operations.len() { return NetworkInvalid("missing operation results") }
        if observed.sequence <= plan.before.sequence { return NetworkReobserve("final observation is not newer") }
        match network_plan(plan.intent, expected, observed) {
          Err(_) => return NetworkReobserve("final observation conflicts with intent")
          Ok(remaining) => {
            if !remaining.operations.is_empty() { return NetworkReobserve("operations acknowledged but state has not converged") }
          }
        }
        for address in plan.before.addresses {
          if address not in plan.owned.addresses and address not in observed.addresses { return NetworkReobserve("foreign address disappeared") }
        }
        for route in plan.before.routes {
          if route not in plan.owned.routes and route not in observed.routes { return NetworkReobserve("foreign route disappeared") }
        }
        for address in plan.owned.addresses {
          if address != plan.intent.address and address in observed.addresses { return NetworkReobserve("retired owned address remains") }
        }
        for route in plan.owned.routes {
          if route not in expected.routes and route in observed.routes { return NetworkReobserve("retired owned route remains") }
        }
        converged = true
      }
    }
  }
  if !converged { return NetworkInvalid("missing final observation") }
  NetworkConverged(expected)
}

pure operation_text(operation: NetworkOperation) -> Str {
  match operation {
    NetworkBringLinkUp => "link up"
    NetworkAddAddress(address) => f"add address {address.local}/{address.prefix}"
    NetworkRemoveAddress(address) => f"remove owned address {address.local}/{address.prefix}"
    NetworkAddDefaultRoute(route) => f"add default via {route.gateway} metric {route.metric}"
    NetworkRemoveDefaultRoute(route) => f"remove owned default via {route.gateway} metric {route.metric}"
  }
}

## Decode plan input as exact data: unknown, duplicate, missing, null and mistyped fields fail with their path before any planning.
export pure network_decode_input(raw: Str) -> Result[NetworkPlanInput, Error] {
  json.decode(raw)?.require_exact()
}

proc main(input: Path) [fs, error] {
  let raw = network_read_input(input)?
  let data = network_decode_input(raw)?
  let plan = network_plan(data.intent, data.owned, data.observed)?
  let operations = [operation_text(operation) for operation in plan.operations]
  print json.encode({ifindex: plan.intent.ifindex, name: plan.intent.name, sequence: plan.before.sequence, operations})?
}
