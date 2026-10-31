##! Capture and offline replay of a disposable Docker veth ownership conflict.
use packages.laputa-net.network_plan as policy

error NetworkCaptureError = Failed(message: Str)
## Selected typed observation, empty ownership, and the exact resulting policy error.
export type NetworkConflictCapture = {input: policy.NetworkPlanInput, error: Str}

pure conflict(input: policy.NetworkPlanInput) -> Result[Str, Error] {
  match policy.network_plan(input.intent, input.owned, input.observed) {
    Err(problem) => Ok(problem.message)
    Ok(_) => Err(NetworkCaptureError.Failed("Docker-owned resources unexpectedly admitted a plan"))
  }
}

## Select the single Docker veth, address and ordinary default route from a complete dump.
export pure select_capture(dump: LinuxNetworkDump) -> Result[NetworkConflictCapture, Error] {
  if !dump.enumeration_succeeded or dump.state != "complete" or !dump.issues.is_empty() {
    return Err(NetworkCaptureError.Failed("network dump is incomplete or contains field issues"))
  }
  let links = [link for link in dump.links if link.kind == "veth"]
  if links.len() != 1 { return Err(NetworkCaptureError.Failed("capture requires exactly one Docker veth")) }
  let link = links[0]
  if link.name == null or link.hardware_type != 1 or link.flags.bit_and(1) == 0 {
    return Err(NetworkCaptureError.Failed("Docker veth identity or link-up state is unavailable"))
  }
  let addresses = [address for address in dump.addresses if address.ifindex == link.ifindex and address.family == "inet"]
  if addresses.len() != 1 { return Err(NetworkCaptureError.Failed("capture requires exactly one selected IPv4 address")) }
  let address = addresses[0]
  if address.local == null or address.local != address.address {
    return Err(NetworkCaptureError.Failed("selected address has no unambiguous local IPv4 value"))
  }
  let routes = [route for route in dump.routes if route.output_ifindex == link.ifindex and route.family == "inet" and route.destination_prefix_length == 0]
  if routes.len() != 1 { return Err(NetworkCaptureError.Failed("capture requires exactly one selected IPv4 default route")) }
  let route = routes[0]
  if route.tos != 0 or route.table != 254 or route.route_type != 1 or route.source_prefix_length != 0 or route.gateway == null or !route.nexthops.is_empty() {
    return Err(NetworkCaptureError.Failed("selected route is outside the supported main-table unicast cohort"))
  }
  let metric = if route.priority == null { 0 } else { route.priority }
  let selected_address: policy.NetworkAddress = {local: address.local, prefix: address.prefix_length}
  let selected_route: policy.NetworkDefaultRoute = {gateway: route.gateway, metric}
  let input: policy.NetworkPlanInput = {
    intent: {ifindex: link.ifindex, name: link.name, address: selected_address, gateway: route.gateway, metric},
    owned: {ifindex: link.ifindex, name: link.name, addresses: [], routes: []},
    observed: {sequence: 1, ifindex: link.ifindex, name: link.name, kind: "veth", up: true, addresses: [selected_address], routes: [selected_route]},
  }
  let problem = conflict(input)?
  if problem != "desired address is foreign; ownership cannot be inferred" {
    return Err(NetworkCaptureError.Failed(f"unexpected ownership conflict: {problem}"))
  }
  Ok({input, error: problem})
}

proc capture() [process, error] -> Result[NetworkConflictCapture, Error] {
  select_capture(linux.network_dump()?)
}

proc main(...argv: List[Str]) [fs, process, error] {
  if argv == ["capture"] {
    let record = capture()?
    let encoded = json.encode(record)?
    if encoded.byte_len() > policy.network_input_limit { return Err(NetworkCaptureError.Failed(f"capture exceeds {policy.network_input_limit} bytes")) }
    print $encoded
  } else if argv.len() == 2 and argv[0] == "replay" {
    let input = argv[1] as Path
    let encoded = policy.network_read_input(input)?
    let record: NetworkConflictCapture = json.decode(encoded)?.require()?
    let first = conflict(record.input)?
    let second = conflict(record.input)?
    if first != record.error or second != record.error {
      return Err(NetworkCaptureError.Failed("offline replay did not reproduce captured error"))
    }
    print $first
  } else {
    return Err(NetworkCaptureError.Failed("expected capture or replay PATH"))
  }
}
