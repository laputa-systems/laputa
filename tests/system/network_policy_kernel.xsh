use packages.laputa-net.network_plan as policy
use packages.laputa-net.network_kernel as kernel
use lib.net_state

pure request_of(plan: policy.NetworkPlan, index: Int) -> Result[net_state.Request, Error] {
  Ok(net_state.request(kernel.network_change(plan, index)?)?)
}

proc fixture_plan() [fs, error] -> Result[policy.NetworkPlan, Error] {
  let raw = p"tests/system/fixtures/network-policy-conflict.json".read_text()?
  let input: policy.NetworkPlanInput = json.decode(raw)?.require()?
  var intent = input.intent
  intent.address.local = "192.0.3.3"
  policy.network_plan(intent, input.owned, input.observed)
}

pure primary_dump() -> LinuxNetworkDump {
  let primary: LinuxNetworkAddress = {address: "192.0.2.2", attributes: [], broadcast: "192.0.2.255", family: "inet", flags: 128, ifindex: 7, label: null, local: "192.0.2.2", preferred_lifetime_seconds: null, prefix_length: 24, scope: 0, valid_lifetime_seconds: null}
  let link: LinuxNetworkLink = {address: null, attributes: [], broadcast: null, flags: 1, hardware_type: 1, ifindex: 7, kind: "veth", lower_ifindex: null, master_ifindex: null, mtu: 1500, name: "veth-test", name_bytes: null, operstate: 6, rx_bytes: 0, tx_bytes: 0}
  {state: "complete", enumeration_succeeded: true, issues: [], links: [link], addresses: [primary], routes: [], rules: []}
}

pure derived_route() -> LinuxNetworkRoute {
  {attributes: [{kind: 15, data: b"\xfe\x00\x00\x00"}, {kind: 1, data: b"\xc0\x00\x02\x00"}, {kind: 7, data: b"\xc0\x00\x02\x02"}, {kind: 4, data: b"\x07\x00\x00\x00"}], destination: "192.0.2.0", destination_prefix_length: 24, family: "inet", flags: 0, gateway: null, input_ifindex: null, nexthops: [], output_ifindex: 7, preferred_source: "192.0.2.2", priority: null, protocol: 2, route_type: 1, scope: 253, source: null, source_prefix_length: 0, table: 254, tos: 0}
}

test test_address_requests_select_exact_local_prefix_and_interface [fs, error] {
  let plan = fixture_plan()?
  let add = request_of(plan, 0)?
  assert add.message_type == 20
  assert add.flags == 1541
  assert add.payload == b"\x02\x18\x00\x00\x07\x00\x00\x00\x08\x00\x01\x00\xc0\x00\x03\x03\x08\x00\x02\x00\xc0\x00\x03\x03"
  let remove = request_of(plan, 1)?
  assert remove.message_type == 21
  assert remove.flags == 5
  assert remove.payload == b"\x02\x18\x00\x00\x07\x00\x00\x00\x08\x00\x01\x00\xc0\x00\x02\x02\x08\x00\x02\x00\xc0\x00\x02\x02"
}

test test_default_route_requests_include_exact_metric_gateway_and_interface [fs, error] {
  let original = fixture_plan()?
  var desired = original.intent
  desired.metric = 101
  let plan = policy.network_plan(desired, original.owned, original.before)?
  let add = request_of(plan, 1)?
  assert add.message_type == 24
  assert add.flags == 1541
  assert add.payload == b"\x02\x00\x00\x00\xfe\x03\x00\x01\x00\x00\x00\x00\x08\x00\x05\x00\xc0\x00\x02\x01\x08\x00\x04\x00\x07\x00\x00\x00\x08\x00\x06\x00\x65\x00\x00\x00\x08\x00\x0f\x00\xfe\x00\x00\x00"
  let remove = request_of(plan, 2)?
  assert remove.message_type == 25
  assert remove.flags == 5
  assert remove.payload == b"\x02\x00\x00\x00\xfe\x03\x00\x01\x00\x00\x00\x00\x08\x00\x05\x00\xc0\x00\x02\x01\x08\x00\x04\x00\x07\x00\x00\x00\x08\x00\x06\x00\x64\x00\x00\x00\x08\x00\x0f\x00\xfe\x00\x00\x00"
}

test test_forged_foreign_removal_is_rejected_before_encoding [fs, error] {
  var plan = fixture_plan()?
  plan.operations = [policy.NetworkRemoveAddress({local: "198.51.100.2", prefix: 24})]
  match kernel.network_change(plan, 0) {
    Err(problem) => assert problem.message == "operation is not part of a valid policy plan"
    Ok(_) => assert false
  }
}

test test_incomplete_dump_never_becomes_empty_success [fs, error] {
  let plan = fixture_plan()?
  let dump: LinuxNetworkDump = {state: "partial", enumeration_succeeded: false, issues: [], links: [], addresses: [], routes: [], rules: []}
  match kernel.network_project_dump(dump, plan.intent, 1) {
    Err(problem) => assert problem.message == "a partial dump reports no issue"
    Ok(_) => assert false
  }
}

test test_secondary_addresses_block_mutation_without_a_promotion_policy [fs, error] {
  let plan = fixture_plan()?
  var dump = primary_dump()
  let secondary: LinuxNetworkAddress = {...dump.addresses[0], address: "192.0.2.3", local: "192.0.2.3", flags: 129}
  dump.addresses = dump.addresses + [secondary]
  match kernel.network_project_dump(dump, plan.intent, 1) {
    Err(problem) => assert problem.message == "selected secondary IPv4 addresses require explicit promotion policy"
    Ok(_) => assert false
  }
}

test test_foreign_route_preferred_source_blocks_even_on_another_interface [fs, error] {
  let plan = fixture_plan()?
  var dump = primary_dump()
  dump.routes = [{attributes: [], destination: "203.0.113.0", destination_prefix_length: 24, family: "inet", flags: 0, gateway: "198.51.100.1", input_ifindex: null, nexthops: [], output_ifindex: 9, preferred_source: "192.0.2.2", priority: 300, protocol: 3, route_type: 1, scope: 0, source: null, source_prefix_length: 0, table: 254, tos: 0}]
  match kernel.network_project_dump(dump, plan.intent, 1) {
    Err(problem) => assert problem.message == "foreign preferred-source route depends on a selected IPv4 address"
    Ok(_) => assert false
  }
}

test test_only_exact_address_derived_kernel_routes_are_excluded_from_foreign_ownership [fs, error] {
  let plan = fixture_plan()?
  var dump = primary_dump()
  dump.routes = [derived_route()]
  let projected = kernel.network_project_dump(dump, plan.intent, 1)?
  assert projected.addresses == [{local: "192.0.2.2", prefix: 24}]
  assert projected.routes.is_empty()
  dump.routes = [{...dump.routes[0], destination: "203.0.113.0"}]
  match kernel.network_project_dump(dump, plan.intent, 1) {
    Err(problem) => assert problem.message == "foreign preferred-source route depends on a selected IPv4 address"
    Ok(_) => assert false
  }
}

test test_customized_kernel_routes_are_never_exempted_as_address_derived [fs, error] {
  let plan = fixture_plan()?
  let original = derived_route()
  let variants: List[LinuxNetworkRoute] = [
    {...original, attributes: original.attributes + [{kind: 8, data: b"\x08\x00\x02\x00\x78\x05\x00\x00"}]},
    {...original, flags: 16},
    {...original, source: "0.0.0.0"},
    {...original, attributes: [{kind: 15, data: b"\xfe\x00\x00\x00"}, {kind: 1, data: b"\xc0\x00\x02\x00"}, {kind: 7, data: b"\xc0\x00\x02\x02"}, {kind: 16388, data: b"\x07\x00\x00\x00"}]},
  ]
  for route in variants {
    var dump = primary_dump()
    dump.routes = [route]
    match kernel.network_project_dump(dump, plan.intent, 1) {
      Err(problem) => assert problem.message == "foreign preferred-source route depends on a selected IPv4 address"
      Ok(_) => assert false, "customized route was treated as an owned address derivative"
    }
  }
}

pure ordinary_default() -> LinuxNetworkRoute {
  {attributes: [{kind: 15, data: b"\xfe\x00\x00\x00"}, {kind: 5, data: b"\xc0\x00\x02\x01"}, {kind: 4, data: b"\x07\x00\x00\x00"}, {kind: 6, data: b"\x64\x00\x00\x00"}], destination: null, destination_prefix_length: 0, family: "inet", flags: 0, gateway: "192.0.2.1", input_ifindex: null, nexthops: [], output_ifindex: 7, preferred_source: null, priority: 100, protocol: 3, route_type: 1, scope: 0, source: null, source_prefix_length: 0, table: 254, tos: 0}
}

proc rejects_default(plan: policy.NetworkPlan, routes: List[LinuxNetworkRoute], message: Str) {
  var dump = primary_dump()
  dump.routes = routes
  match kernel.network_project_dump(dump, plan.intent, 1) {
    Err(problem) => assert problem.message == message
    Ok(_) => assert false, message
  }
}

test test_ordinary_selected_default_route_projects_with_exact_gateway_and_metric [fs, error] {
  let plan = fixture_plan()?
  var dump = primary_dump()
  dump.routes = [ordinary_default()]
  let snapshot = kernel.network_project_dump(dump, plan.intent, 1)?
  assert snapshot.routes == [{gateway: "192.0.2.1", metric: 100}]
}

test test_tos_specific_default_never_converges_with_an_ordinary_default [fs, error] {
  let plan = fixture_plan()?
  var specific = ordinary_default()
  specific.tos = 8
  let message = "selected default route is TOS-specific and cannot converge with ordinary traffic"
  rejects_default(plan, [specific], message)
  rejects_default(plan, [ordinary_default(), specific], message)
}

test test_default_routes_on_other_interfaces_are_not_projected [fs, error] {
  let plan = fixture_plan()?
  var foreign = ordinary_default()
  foreign.output_ifindex = 9
  foreign.tos = 8
  var dump = primary_dump()
  dump.routes = [foreign]
  let snapshot = kernel.network_project_dump(dump, plan.intent, 1)?
  assert snapshot.routes.is_empty()
}

test test_customized_selected_default_routes_are_refused [fs, error] {
  let plan = fixture_plan()?
  var protocol = ordinary_default()
  protocol.protocol = 4
  rejects_default(plan, [protocol], "selected default route is outside the supported main-table unicast cohort")
  var table = ordinary_default()
  table.table = 100
  rejects_default(plan, [table], "selected default route is outside the supported main-table unicast cohort")
  var mtu = ordinary_default()
  mtu.attributes += [{kind: 8, data: b"\x00\x00\x00\x00"}]
  rejects_default(plan, [mtu], "selected default route carries unsupported attributes")
}

test test_same_prefix_addition_is_rejected_before_any_request [fs, error] {
  let original = fixture_plan()?
  var desired = original.intent
  desired.address.local = "192.0.2.3"
  let plan = policy.network_plan(desired, original.owned, original.before)?
  match kernel.network_change(plan, 0) {
    Err(problem) => assert problem.message == "same-prefix IPv4 additions require explicit promotion policy"
    Ok(_) => assert false
  }
}

test test_consecutive_dumps_must_agree_before_projection [fs, error] {
  let plan = fixture_plan()?
  var first = primary_dump()
  first.routes = [ordinary_default()]
  let state = net_state.project(first)?
  let snapshot = kernel.network_project_stable_states(state, state, plan.intent, 1)?
  assert snapshot.routes.len() == 1
  var changed = first
  changed.routes = [{...ordinary_default(), priority: 200, attributes: [{kind: 15, data: b"\xfe\x00\x00\x00"}, {kind: 5, data: b"\xc0\x00\x02\x01"}, {kind: 4, data: b"\x07\x00\x00\x00"}, {kind: 6, data: b"\xc8\x00\x00\x00"}]}]
  match kernel.network_project_stable_states(state, net_state.project(changed)?, plan.intent, 1) {
    Err(problem) => assert problem.message == "network observation changed between consecutive dumps"
    Ok(_) => assert false
  }
}

test test_outcomes_and_lost_notices_map_to_replay_events [fs, error] {
  assert kernel.network_outcome(2, Ok()) == policy.NetworkApplied(2)
  assert kernel.network_outcome(2, Err(net_state.ChangeFailure.Refused(errno: 101, message: "Network is unreachable"))) == policy.NetworkDenied(2)
  assert kernel.network_outcome(2, Err(net_state.ChangeFailure.Transport("deadline"))) == policy.NetworkFailed(2)
  assert kernel.network_outcome(2, Err(net_state.ChangeFailure.Unencodable("multipath"))) == policy.NetworkFailed(2)
  assert kernel.network_lost_events(net_state.Lost("overrun")) == policy.NetworkLostEvents
  assert kernel.network_lost_events(net_state.Changed) == null
  assert kernel.network_lost_events(net_state.Quiet) == null
}

pure retired_route_plan() -> Result[policy.NetworkPlan, Error] {
  let observed: policy.NetworkSnapshot = {
    sequence: 1, ifindex: 7, name: "veth-test", kind: "veth", up: true,
    addresses: [{local: "192.0.2.2", prefix: 24}],
    routes: [{gateway: "192.0.2.1", metric: 100}, {gateway: "192.0.2.1", metric: 300}],
  }
  let owned: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [intent().address], routes: [{gateway: "192.0.2.1", metric: 100}, {gateway: "192.0.2.1", metric: 300}]}
  policy.network_plan(intent(), owned, observed)
}

pure intent() -> policy.NetworkIntent {
  {ifindex: 7, name: "veth-test", address: {local: "192.0.2.2", prefix: 24}, gateway: "192.0.2.1", metric: 100}
}

test test_retired_owned_default_route_with_a_nonzero_metric_is_removable [fs, error] {
  let plan = retired_route_plan()?
  assert plan.operations == [policy.NetworkRemoveDefaultRoute({gateway: "192.0.2.1", metric: 300})]
  match kernel.network_change(plan, 0) {
    Ok(net_state.RemoveRoute(route)) => {
      assert route.priority == 300
      assert route.protocol == 3
      assert route.route_type == 1
      assert route.table == net_state.TABLE_MAIN
      assert route.other_attributes.is_empty()
    }
    Ok(_) => assert false, "retired route did not become a route removal"
    Err(problem) => assert false, problem.message
  }
}

test test_zero_metric_default_route_removal_is_refused_before_any_request [error] {
  let observed: policy.NetworkSnapshot = {
    sequence: 1, ifindex: 7, name: "veth-test", kind: "veth", up: true,
    addresses: [{local: "192.0.2.2", prefix: 24}],
    routes: [{gateway: "192.0.2.1", metric: 0}, {gateway: "192.0.2.1", metric: 300}],
  }
  let owned: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [intent().address], routes: [{gateway: "192.0.2.1", metric: 0}]}
  let plan = policy.network_plan(intent(), owned, observed)?
  assert plan.operations == [policy.NetworkAddDefaultRoute({gateway: "192.0.2.1", metric: 100}), policy.NetworkRemoveDefaultRoute({gateway: "192.0.2.1", metric: 0})]
  let message = "a zero-metric default route cannot be removed exactly; the kernel treats a zero priority as a wildcard over every metric"
  assert kernel.network_change(plan, 0) == Ok(net_state.AddRoute({family: .Inet, table: net_state.TABLE_MAIN, destination: null, prefix: 0, source: null, source_prefix: 0, preferred_source: null, tos: 0, priority: 100, protocol: 3, scope: 0, route_type: 1, flags: 0, hops: [{ifindex: 7, gateway: "192.0.2.1"}], other_attributes: []}))
  match kernel.network_change(plan, 0) {
    Ok(_) => {}
    Err(problem) => assert false, problem.message
  }
  match kernel.network_change(plan, 1) {
    Err(problem) => assert problem.message == message
    Ok(_) => assert false, message
  }
  match kernel.network_changes(plan) {
    Err(problem) => assert problem.message == message
    Ok(_) => assert false, "a whole plan encoded a zero-metric removal"
  }
}

pure empty_snapshot() -> policy.NetworkSnapshot {
  {sequence: 1, ifindex: 7, name: "veth-test", kind: "veth", up: true, addresses: [], routes: []}
}

pure empty_ownership() -> policy.NetworkOwnership {
  {ifindex: 7, name: "veth-test", addresses: [], routes: []}
}

test test_change_set_is_complete_ordered_and_empty_for_a_no_change_plan [error] {
  let plan = policy.network_plan(intent(), empty_ownership(), empty_snapshot())?
  assert plan.operations == [policy.NetworkAddAddress(intent().address), policy.NetworkAddDefaultRoute({gateway: "192.0.2.1", metric: 100})]
  let changes = kernel.network_changes(plan)?
  assert changes == [net_state.AddAddress({ifindex: 7, family: .Inet, local: "192.0.2.2", prefix: 24, peer: null, broadcast: null, scope: 0, flags: 0}), net_state.AddRoute({family: .Inet, table: net_state.TABLE_MAIN, destination: null, prefix: 0, source: null, source_prefix: 0, preferred_source: null, tos: 0, priority: 100, protocol: 3, scope: 0, route_type: 1, flags: 0, hops: [{ifindex: 7, gateway: "192.0.2.1"}], other_attributes: []})]
  for index in range(changes.len()) {
    assert changes[index] == kernel.network_change(plan, index)?
  }
  match kernel.network_change(plan, changes.len()) {
    Err(problem) => assert problem.message == "operation is not part of a valid policy plan"
    Ok(_) => assert false
  }
  var settled = empty_snapshot()
  settled.up = true
  settled.addresses = [intent().address]
  settled.routes = [{gateway: "192.0.2.1", metric: 100}]
  let owned: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [intent().address], routes: [{gateway: "192.0.2.1", metric: 100}]}
  let no_change = policy.network_plan(intent(), owned, settled)?
  assert no_change.operations.is_empty()
  assert kernel.network_changes(no_change)?.is_empty()
  match kernel.network_change(no_change, 0) {
    Err(problem) => assert problem.message == "operation is not part of a valid policy plan"
    Ok(_) => assert false, "a no-change plan produced a change"
  }
}

test test_unmodeled_route_attributes_never_become_a_removal [fs, error] {
  let plan = fixture_plan()?
  var customized = ordinary_default()
  customized.attributes += [{kind: 8, data: b"\x00\x00\x00\x00"}]
  var dump = primary_dump()
  dump.routes = [customized]
  match kernel.network_project_dump(dump, plan.intent, 1) {
    Err(problem) => assert problem.message == "selected default route carries unsupported attributes"
    Ok(_) => assert false, "a customized route entered the projected cohort"
  }
  let selected = net_state.project(dump)?
  let route = selected.routes[0]
  assert route.other_attributes == [8]
  match net_state.request(net_state.RemoveRoute(route)) {
    Ok(encoded) => assert encoded.message_type == 25
    Err(_) => assert false, "an unexpected removal encode failure"
  }
  match net_state.request(net_state.AddRoute(route)) {
    Err(net_state.ChangeFailure.Unencodable {message}) => assert "cannot be encoded" in message
    Ok(_) => assert false, "an addition silently dropped an unmodeled attribute"
  }
}

test test_projected_route_identity_matches_the_removal_request_exactly [fs, error] {
  let plan = fixture_plan()?
  var dump = primary_dump()
  dump.routes = [ordinary_default()]
  let state = net_state.project(dump)?
  let projected = kernel.network_project_state(state, plan.intent, 1)?
  assert projected.routes == [{gateway: "192.0.2.1", metric: 100}]
  let settled: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [{local: "192.0.2.2", prefix: 24}], routes: [{gateway: "192.0.2.1", metric: 100}]}
  let desired = policy.network_plan({...plan.intent, address: {local: "192.0.2.2", prefix: 24}}, settled, projected)?
  assert desired.operations.is_empty()
  let removal = policy.network_plan({...plan.intent, address: {local: "192.0.2.2", prefix: 24}, metric: 200}, {ifindex: 7, name: "veth-test", addresses: [{local: "192.0.2.2", prefix: 24}], routes: [{gateway: "192.0.2.1", metric: 100}]}, projected)?
  assert removal.operations == [policy.NetworkAddDefaultRoute({gateway: "192.0.2.1", metric: 200}), policy.NetworkRemoveDefaultRoute({gateway: "192.0.2.1", metric: 100})]
  let removal_request = net_state.request(kernel.network_change(removal, 1)?)?
  assert removal_request.message_type == 25
  let addition_request = net_state.request(kernel.network_change(removal, 0)?)?
  assert addition_request.message_type == 24
  let observed = state.routes[0]
  assert observed.table == net_state.TABLE_MAIN
  assert observed.tos == 0
  assert observed.protocol == 3
  assert observed.route_type == 1
  assert observed.scope == 0
  assert observed.flags == 0
  assert observed.other_attributes.is_empty()
  assert addition_request.payload == bytes.concat([bytes.from_ints([2, 0, 0, 0, 254, 3, 0, 1])?, bytes.zero(4)?, b"\x08\x00\x05\x00\xc0\x00\x02\x01", b"\x08\x00\x04\x00\x07\x00\x00\x00", b"\x08\x00\x06\x00\xc8\x00\x00\x00", b"\x08\x00\x0f\x00\xfe\x00\x00\x00"])
  assert removal_request.payload == bytes.concat([bytes.from_ints([2, 0, 0, 0, 254, 3, 0, 1])?, bytes.zero(4)?, b"\x08\x00\x05\x00\xc0\x00\x02\x01", b"\x08\x00\x04\x00\x07\x00\x00\x00", b"\x08\x00\x06\x00\x64\x00\x00\x00", b"\x08\x00\x0f\x00\xfe\x00\x00\x00"])
}

test test_reconcile_result_reports_conflicts_instead_of_rolling_back [fs, error] {
  let plan = healthy_plan()?
  assert plan.operations == [policy.NetworkAddAddress({local: "192.0.2.3", prefix: 24}), policy.NetworkRemoveAddress({local: "192.0.2.2", prefix: 24})]
  let stale: policy.NetworkSnapshot = {...plan.before, sequence: 2, routes: []}
  let conflict: kernel.NetworkReconcile = {
    plan,
    attempts: 0,
    observed: stale,
    events: [policy.NetworkPrecondition(plan.before)],
    result: policy.NetworkReobserve("observation changed before operation 0"),
  }
  assert conflict.attempts == 0
  match conflict.result {
    policy.NetworkReobserve(reason) => assert reason == "observation changed before operation 0"
    else => assert false
  }
  let diverged: kernel.NetworkReconcile = {...conflict, attempts: 1, result: policy.NetworkReobserve("operation 0 was acknowledged but the observation diverged")}
  match diverged.result {
    policy.NetworkReobserve(reason) => assert reason == "operation 0 was acknowledged but the observation diverged"
    else => assert false
  }
  assert kernel.same_cohort(plan.before, {...plan.before, sequence: 9})
  assert !kernel.same_cohort(plan.before, stale)
}

proc healthy_plan() [fs, error] -> Result[policy.NetworkPlan, Error] {
  let raw = p"tests/system/fixtures/network-policy-conflict.json".read_text()?
  let input: policy.NetworkPlanInput = json.decode(raw)?.require()?
  policy.network_plan(input.intent, input.owned, input.observed)
}

pure intent6() -> policy.NetworkIntent {
  {ifindex: 7, name: "veth-test", address: {local: "2001:db8:1::2", prefix: 64}, gateway: "fe80::1", metric: 0}
}

pure address6(local: Str, flags: Int, scope: Int) -> LinuxNetworkAddress {
  {address: local, attributes: [], broadcast: null, family: "inet6", flags, ifindex: 7, label: null, local: null, preferred_lifetime_seconds: null, prefix_length: 64, scope, valid_lifetime_seconds: null}
}

pure default6(gateway: Str, metric: Int) -> LinuxNetworkRoute {
  {attributes: [{kind: 15, data: b""}, {kind: 5, data: b""}, {kind: 4, data: b""}, {kind: 6, data: b""}, {kind: 12, data: b""}, {kind: 20, data: b""}], destination: null, destination_prefix_length: 0, family: "inet6", flags: 0, gateway, input_ifindex: null, nexthops: [], output_ifindex: 7, preferred_source: null, priority: metric, protocol: 3, route_type: 1, scope: 0, source: null, source_prefix_length: 0, table: 254, tos: 0}
}

pure dump6(addresses: List[LinuxNetworkAddress], routes: List[LinuxNetworkRoute]) -> LinuxNetworkDump {
  {...primary_dump(), addresses, routes}
}

const static6 = 192
const settled6 = 128

proc rejects6(addresses: List[LinuxNetworkAddress], routes: List[LinuxNetworkRoute], message: Str) {
  match kernel.network_project_dump(dump6(addresses, routes), intent6(), 1) {
    Err(problem) => assert problem.message == message, problem.message
    Ok(_) => assert false, message
  }
}

test test_ipv6_cohort_projects_static_addresses_and_defaults_and_ignores_kernel_managed_state [error] {
  let addresses = [
    address6("2001:db8:1::2", static6, 0),
    address6("2001:db8:ff::2", settled6, 0),
    address6("fe80::ff:fe00:3201", static6, 253),
    address6("2001:db8:2::99", 0, 0),
    address6("2001:db8:2::98", 1, 0),
    address6("2001:db8:2::97", 64, 0),
  ]
  let routes = [default6("fe80::1", 1024), default6("2001:db8:1::1", 300)]
  let projected = kernel.network_project_dump(dump6(addresses, routes), intent6(), 1)?
  assert projected.addresses == [{local: "2001:db8:1::2", prefix: 64}, {local: "2001:db8:ff::2", prefix: 64}]
  assert projected.routes == [{gateway: "2001:db8:1::1", metric: 300}, {gateway: "fe80::1", metric: 1024}]
  assert projected.kind == "veth" and projected.up
  let settled: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [{local: "2001:db8:1::2", prefix: 64}], routes: [{gateway: "fe80::1", metric: 1024}]}
  let plan = policy.network_plan(intent6(), settled, projected)?
  assert plan.operations.is_empty()
}

test test_ipv6_tentative_address_is_present_and_duplicate_detection_failure_is_explicit [error] {
  let tentative = kernel.network_project_dump(dump6([address6("2001:db8:1::2", 192, 0), address6("2001:db8:1::3", 128 + 64 + 4, 0)], []), intent6(), 1)?
  assert tentative.addresses == [{local: "2001:db8:1::2", prefix: 64}, {local: "2001:db8:1::3", prefix: 64}]
  let settled = kernel.network_project_dump(dump6([address6("2001:db8:1::2", 128, 0), address6("2001:db8:1::3", 128, 0)], []), intent6(), 2)?
  assert kernel.same_cohort(tentative, settled)
  rejects6([address6("2001:db8:1::2", 128 + 64 + 8, 0)], [], "selected IPv6 address failed duplicate address detection")
  rejects6([address6("2001:db8:1::2", 128 + 8, 0)], [], "selected IPv6 address failed duplicate address detection")
}

test test_ipv6_addresses_outside_the_static_global_cohort_are_refused [error] {
  let flagged = "selected IPv6 address carries flags that require explicit policy"
  for flags in [128 + 16, 128 + 256, 128 + 512, 128 + 1024, 128 + 2048, 128 + 1] {
    rejects6([address6("2001:db8:1::2", flags, 0)], [], flagged)
  }
  let scoped = "selected IPv6 address is outside the global unicast cohort"
  rejects6([address6("2001:db8:1::2", 128, 5)], [], scoped)
  rejects6([address6("2001:db8:1::2", 128, 254)], [], scoped)
  let peered: LinuxNetworkAddress = {...address6("2001:db8:1::2", 128, 0), local: "2001:db8:1::2", address: "2001:db8:1::9"}
  rejects6([peered], [], scoped)
}

test test_ipv6_default_routes_follow_the_same_exact_cohort_as_ipv4 [error] {
  let outside = "selected default route is outside the supported main-table unicast cohort"
  var static_proto = default6("fe80::1", 1024)
  static_proto.protocol = 4
  rejects6([], [static_proto], outside)
  var table = default6("fe80::1", 1024)
  table.table = 100
  rejects6([], [table], outside)
  var linkdown = default6("fe80::1", 1024)
  linkdown.flags = 16
  rejects6([], [linkdown], outside)
  var preferred = default6("fe80::1", 1024)
  preferred.preferred_source = "2001:db8:ff::7"
  rejects6([], [preferred], outside)
  var tos = default6("fe80::1", 1024)
  tos.tos = 8
  rejects6([], [default6("fe80::2", 1025), tos], "selected default route is TOS-specific and cannot converge with ordinary traffic")
  var metrics = default6("fe80::1", 1024)
  metrics.attributes += [{kind: 8, data: b""}]
  rejects6([], [metrics], "selected default route carries unsupported attributes")
  var multipath = default6("fe80::1", 1024)
  multipath.nexthops = [{ifindex: 7, gateway: "fe80::1", hops: 0, flags: 0}, {ifindex: 7, gateway: "fe80::2", hops: 0, flags: 0}]
  rejects6([], [multipath], outside)
  var elsewhere = default6("fe80::1", 1024)
  elsewhere.output_ifindex = 9
  elsewhere.tos = 8
  let ignored = kernel.network_project_dump(dump6([], [elsewhere]), intent6(), 1)?
  assert ignored.routes.is_empty()
}

test test_router_advertisement_defaults_are_foreign_state_outside_the_cohort [error] {
  var advertised = default6("fe80::aa", 1024)
  advertised.protocol = 9
  var expiring = default6("fe80::ab", 1024)
  expiring.protocol = 9
  expiring.attributes += [{kind: 23, data: b""}]
  let projected = kernel.network_project_dump(dump6([address6("2001:db8:1::2", settled6, 0)], [advertised, expiring, default6("fe80::1", 300)]), intent6(), 1)?
  assert projected.routes == [{gateway: "fe80::1", metric: 300}]
  let plan = policy.network_plan(intent6(), {ifindex: 7, name: "veth-test", addresses: [{local: "2001:db8:1::2", prefix: 64}], routes: [{gateway: "fe80::1", metric: 300}]}, projected)?
  for operation in plan.operations {
    match operation {
      policy.NetworkRemoveDefaultRoute(route) => assert route.gateway == "fe80::1"
      else => {}
    }
  }
  let retired = policy.network_plan(intent6(), {ifindex: 7, name: "veth-test", addresses: [{local: "2001:db8:1::2", prefix: 64}], routes: [{gateway: "fe80::1", metric: 300}]}, projected)?
  assert retired.operations == [policy.NetworkAddDefaultRoute({gateway: "fe80::1", metric: 1024}), policy.NetworkRemoveDefaultRoute({gateway: "fe80::1", metric: 300})]
}

test test_ipv6_preferred_source_dependencies_on_selected_addresses_are_refused [error] {
  var dependent: LinuxNetworkRoute = {...default6("fe80::1", 1024), destination: "2001:db8:9::", destination_prefix_length: 64, preferred_source: "2001:db8:1::2", output_ifindex: 9}
  rejects6([address6("2001:db8:1::2", settled6, 0)], [dependent], "foreign preferred-source route depends on a selected IPv6 address")
  dependent.preferred_source = "2001:db8:1::77"
  let projected = kernel.network_project_dump(dump6([address6("2001:db8:1::2", settled6, 0)], [dependent]), intent6(), 1)?
  assert projected.routes.is_empty()
}

test test_each_family_ignores_the_other_familys_state_even_when_it_is_unsupported [fs, error] {
  var mixed = primary_dump()
  mixed.addresses = mixed.addresses + [address6("2001:db8:1::2", 128 + 64 + 8, 0), address6("2001:db8:1::5", 128, 5)]
  mixed.routes = [ordinary_default(), default6("fe80::1", 1024)]
  let v4 = kernel.network_project_dump(mixed, fixture_plan()?.intent, 1)?
  assert v4.addresses == [{local: "192.0.2.2", prefix: 24}]
  assert v4.routes == [{gateway: "192.0.2.1", metric: 100}]
  var v6_mixed = primary_dump()
  let secondary: LinuxNetworkAddress = {...v6_mixed.addresses[0], address: "192.0.2.3", local: "192.0.2.3", flags: 129}
  v6_mixed.addresses = [secondary, v6_mixed.addresses[0], address6("2001:db8:1::2", 128, 0)]
  var tos = ordinary_default()
  tos.tos = 8
  v6_mixed.routes = [tos, default6("fe80::1", 1024)]
  let v6 = kernel.network_project_dump(v6_mixed, intent6(), 1)?
  assert v6.addresses == [{local: "2001:db8:1::2", prefix: 64}]
  assert v6.routes == [{gateway: "fe80::1", metric: 1024}]
}

test test_ipv6_incomplete_dumps_and_issues_never_become_empty_success [error] {
  let partial: LinuxNetworkDump = {state: "partial", enumeration_succeeded: false, issues: [], links: [], addresses: [], routes: [], rules: []}
  match kernel.network_project_dump(partial, intent6(), 1) {
    Err(problem) => assert problem.message == "a partial dump reports no issue"
    Ok(_) => assert false
  }
  for object in ["address", "route", "link", "socket"] {
    let issue: LinuxNetworkIssue = {errno: null, error_kind: "protocol", message: f"{object} dump was cut short", object, state: "truncated"}
    let truncated: LinuxNetworkDump = {...dump6([address6("2001:db8:1::2", settled6, 0)], [default6("fe80::1", 1024)]), state: "partial", enumeration_succeeded: false, issues: [issue]}
    match kernel.network_project_dump(truncated, intent6(), 1) {
      Err(problem) => assert f"{object} dump was cut short" in problem.message, problem.message
      Ok(_) => assert false, f"a truncated {object} dump projected"
    }
  }
}

test test_ipv6_consecutive_dumps_must_agree_before_projection [error] {
  let first = net_state.project(dump6([address6("2001:db8:1::2", static6, 0)], [default6("fe80::1", 1024)]))?
  let again = net_state.project(dump6([address6("2001:db8:1::2", settled6, 0)], [default6("fe80::1", 1024)]))?
  match kernel.network_project_stable_states(first, again, intent6(), 1) {
    Err(problem) => assert problem.message == "network observation changed between consecutive dumps"
    Ok(_) => assert false, "duplicate address detection settling is a changed observation, not a stable one"
  }
  let settled = net_state.project(dump6([address6("2001:db8:1::2", settled6, 0)], [default6("fe80::1", 1024)]))?
  let snapshot = kernel.network_project_stable_states(settled, settled, intent6(), 1)?
  assert snapshot.addresses == [{local: "2001:db8:1::2", prefix: 64}]
  let changed = net_state.project(dump6([address6("2001:db8:1::2", settled6, 0)], [default6("fe80::1", 300)]))?
  match kernel.network_project_stable_states(settled, changed, intent6(), 1) {
    Err(problem) => assert problem.message == "network observation changed between consecutive dumps"
    Ok(_) => assert false
  }
}

pure empty6() -> policy.NetworkSnapshot {
  {sequence: 1, ifindex: 7, name: "veth-test", kind: "veth", up: true, addresses: [], routes: []}
}

test test_ipv6_change_set_is_typed_complete_and_ordered [error] {
  let plan = policy.network_plan(intent6(), empty_ownership(), empty6())?
  assert plan.operations == [policy.NetworkAddAddress({local: "2001:db8:1::2", prefix: 64}), policy.NetworkAddDefaultRoute({gateway: "fe80::1", metric: 1024})]
  let changes = kernel.network_changes(plan)?
  assert changes == [
    net_state.AddAddress({ifindex: 7, family: .Inet6, local: "2001:db8:1::2", prefix: 64, peer: null, broadcast: null, scope: 0, flags: 0}),
    net_state.AddRoute({family: .Inet6, table: net_state.TABLE_MAIN, destination: null, prefix: 0, source: null, source_prefix: 0, preferred_source: null, tos: 0, priority: 1024, protocol: 3, scope: 0, route_type: 1, flags: 0, hops: [{ifindex: 7, gateway: "fe80::1"}], other_attributes: []}),
  ]
  for index in range(changes.len()) {
    assert changes[index] == kernel.network_change(plan, index)?
  }
}

test test_ipv6_requests_select_exact_local_prefix_gateway_interface_and_metric [error] {
  let plan = policy.network_plan({...intent6(), address: {local: "2001:db8:1::3", prefix: 64}, gateway: "2001:db8:1::1", metric: 200}, {ifindex: 7, name: "veth-test", addresses: [{local: "2001:db8:1::2", prefix: 64}], routes: [{gateway: "fe80::1", metric: 1024}]}, {...empty6(), addresses: [{local: "2001:db8:1::2", prefix: 64}], routes: [{gateway: "fe80::1", metric: 1024}]})?
  assert plan.operations == [
    policy.NetworkAddAddress({local: "2001:db8:1::3", prefix: 64}),
    policy.NetworkAddDefaultRoute({gateway: "2001:db8:1::1", metric: 200}),
    policy.NetworkRemoveDefaultRoute({gateway: "fe80::1", metric: 1024}),
    policy.NetworkRemoveAddress({local: "2001:db8:1::2", prefix: 64}),
  ]
  let local = b"\x20\x01\x0d\xb8\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03"
  let old = b"\x20\x01\x0d\xb8\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02"
  let global_gateway = b"\x20\x01\x0d\xb8\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01"
  let link_gateway = b"\xfe\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01"
  let add = request_of(plan, 0)?
  assert add.message_type == 20 and add.flags == 1541
  assert add.payload == bytes.concat([b"\x0a\x40\x00\x00\x07\x00\x00\x00", b"\x14\x00\x01\x00", local, b"\x14\x00\x02\x00", local])
  let remove = request_of(plan, 3)?
  assert remove.message_type == 21 and remove.flags == 5
  assert remove.payload == bytes.concat([b"\x0a\x40\x00\x00\x07\x00\x00\x00", b"\x14\x00\x01\x00", old, b"\x14\x00\x02\x00", old])
  let route_head = bytes.concat([bytes.from_ints([10, 0, 0, 0, 254, 3, 0, 1])?, bytes.zero(4)?])
  let route_add = request_of(plan, 1)?
  assert route_add.message_type == 24 and route_add.flags == 1541
  assert route_add.payload == bytes.concat([route_head, b"\x14\x00\x05\x00", global_gateway, b"\x08\x00\x04\x00\x07\x00\x00\x00", b"\x08\x00\x06\x00\xc8\x00\x00\x00", b"\x08\x00\x0f\x00\xfe\x00\x00\x00"])
  let route_remove = request_of(plan, 2)?
  assert route_remove.message_type == 25 and route_remove.flags == 5
  assert route_remove.payload == bytes.concat([route_head, b"\x14\x00\x05\x00", link_gateway, b"\x08\x00\x04\x00\x07\x00\x00\x00", b"\x08\x00\x06\x00\x00\x04\x00\x00", b"\x08\x00\x0f\x00\xfe\x00\x00\x00"])
}

test test_ipv6_has_no_primary_secondary_rule_so_same_prefix_additions_are_planned [error] {
  let observed: policy.NetworkSnapshot = {...empty6(), addresses: [{local: "2001:db8:1::2", prefix: 64}]}
  let owned: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [{local: "2001:db8:1::2", prefix: 64}], routes: []}
  let plan = policy.network_plan({...intent6(), address: {local: "2001:db8:1::3", prefix: 64}}, owned, observed)?
  assert plan.operations[0] == policy.NetworkAddAddress({local: "2001:db8:1::3", prefix: 64})
  let changes = kernel.network_changes(plan)?
  assert changes.len() == plan.operations.len()
}

test test_ipv6_zero_metric_is_never_sent_and_a_zero_metric_removal_is_refused [error] {
  let plan = policy.network_plan(intent6(), empty_ownership(), empty6())?
  let changes = kernel.network_changes(plan)?
  match changes[1] {
    net_state.AddRoute(route) => assert route.priority == 1024
    else => assert false, "the default route was not added"
  }
  let observed: policy.NetworkSnapshot = {...empty6(), routes: [{gateway: "fe80::9", metric: 0}]}
  let owned: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [], routes: [{gateway: "fe80::9", metric: 0}]}
  let retiring = policy.network_plan(intent6(), owned, observed)?
  assert policy.NetworkRemoveDefaultRoute({gateway: "fe80::9", metric: 0}) in retiring.operations
  let message = "a zero-metric default route cannot be removed exactly; the kernel treats a zero priority as a wildcard over every metric"
  match kernel.network_changes(retiring) {
    Err(problem) => assert problem.message == message
    Ok(_) => assert false, "a zero-metric IPv6 removal was encoded"
  }
}

test test_forged_ipv6_operations_are_rejected_before_encoding [error] {
  let plan = policy.network_plan(intent6(), empty_ownership(), empty6())?
  var forged = plan
  forged.operations = [policy.NetworkRemoveAddress({local: "2001:db8:ff::2", prefix: 64})]
  match kernel.network_changes(forged) {
    Err(problem) => assert problem.message == "operation is not part of a valid policy plan"
    Ok(_) => assert false
  }
  var extended = plan
  extended.operations = plan.operations + [policy.NetworkRemoveDefaultRoute({gateway: "fe80::bad", metric: 1024})]
  match kernel.network_change(extended, 0) {
    Err(problem) => assert problem.message == "operation is not part of a valid policy plan"
    Ok(_) => assert false
  }
  var stale = plan
  stale.before = {...plan.before, up: false}
  match kernel.network_changes(stale) {
    Err(problem) => assert problem.message == "operation is not part of a valid policy plan"
    Ok(_) => assert false, "a plan whose precondition no longer matches its operations was accepted"
  }
}

test test_ipv6_refusal_by_a_disabled_stack_is_a_denial_not_an_error_or_success [error] {
  let denied = net_state.ChangeFailure.Refused(errno: 13, message: net_state.errno_text(13))
  assert kernel.network_outcome(0, Err(denied)) == policy.NetworkDenied(0)
  assert net_state.errno_text(13) == "errno 13"
}

test test_package_ipv6_policy_keeps_the_kernel_from_changing_the_static_cohort [fs, error] {
  let policy_text = p"packages/laputa-net/ipv6.conf".read_text()?
  let lines = [line.trim() for line in policy_text.split("\n") if !line.trim().is_empty()]
  for scope in ["all", "default"] {
    for setting in ["disable_ipv6 = 1", "accept_ra = 0", "autoconf = 0"] {
      assert f"net.ipv6.conf.{scope}.{setting}" in lines, f"{scope} {setting}"
    }
  }
  let interfaces = p"packages/laputa-net/interfaces".read_text()?
  assert "inet6" not in interfaces
}
