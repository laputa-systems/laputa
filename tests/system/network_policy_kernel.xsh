use packages.laputa-net.network_plan as policy
use packages.laputa-net.network_kernel as kernel

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
  let add = kernel.network_encode_operation(plan, 0)?
  assert add.message_type == 20
  assert add.flags == 1541
  assert add.payload == b"\x02\x18\x00\x00\x07\x00\x00\x00\x08\x00\x01\x00\xc0\x00\x03\x03\x08\x00\x02\x00\xc0\x00\x03\x03"
  let remove = kernel.network_encode_operation(plan, 1)?
  assert remove.message_type == 21
  assert remove.flags == 5
  assert remove.payload == b"\x02\x18\x00\x00\x07\x00\x00\x00\x08\x00\x01\x00\xc0\x00\x02\x02\x08\x00\x02\x00\xc0\x00\x02\x02"
}

test test_default_route_requests_include_exact_metric_gateway_and_interface [fs, error] {
  let original = fixture_plan()?
  var desired = original.intent
  desired.metric = 101
  let plan = policy.network_plan(desired, original.owned, original.before)?
  let add = kernel.network_encode_operation(plan, 1)?
  assert add.message_type == 24
  assert add.flags == 1541
  assert add.payload == b"\x02\x00\x00\x00\xfe\x03\x00\x01\x00\x00\x00\x00\x08\x00\x04\x00\x07\x00\x00\x00\x08\x00\x05\x00\xc0\x00\x02\x01\x08\x00\x06\x00\x65\x00\x00\x00"
  let remove = kernel.network_encode_operation(plan, 2)?
  assert remove.message_type == 25
  assert remove.flags == 5
  assert remove.payload == b"\x02\x00\x00\x00\xfe\x00\x00\x01\x00\x00\x00\x00\x08\x00\x04\x00\x07\x00\x00\x00\x08\x00\x05\x00\xc0\x00\x02\x01\x08\x00\x06\x00\x64\x00\x00\x00"
}

test test_forged_foreign_removal_is_rejected_before_encoding [fs, error] {
  var plan = fixture_plan()?
  plan.operations = [policy.NetworkRemoveAddress({local: "198.51.100.2", prefix: 24})]
  match kernel.network_encode_operation(plan, 0) {
    Err(problem) => assert problem.message == "operation is not part of a valid policy plan"
    Ok(_) => assert false
  }
}

test test_incomplete_dump_never_becomes_empty_success [fs, error] {
  let plan = fixture_plan()?
  let dump: LinuxNetworkDump = {state: "partial", enumeration_succeeded: false, issues: [], links: [], addresses: [], routes: [], rules: []}
  match kernel.network_project_dump(dump, plan.intent, 1) {
    Err(problem) => assert problem.message == "complete issue-free network observation required"
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
  match kernel.network_encode_operation(plan, 0) {
    Err(problem) => assert problem.message == "same-prefix IPv4 additions require explicit promotion policy"
    Ok(_) => assert false
  }
}

test test_consecutive_dumps_must_agree_before_projection [fs, error] {
  let plan = fixture_plan()?
  var first = primary_dump()
  first.routes = [ordinary_default()]
  let snapshot = kernel.network_project_stable_dumps(first, first, plan.intent, 1)?
  assert snapshot.routes.len() == 1
  var changed = first
  changed.routes = [{...ordinary_default(), priority: 200, attributes: [{kind: 15, data: b"\xfe\x00\x00\x00"}, {kind: 5, data: b"\xc0\x00\x02\x01"}, {kind: 4, data: b"\x07\x00\x00\x00"}, {kind: 6, data: b"\xc8\x00\x00\x00"}]}]
  match kernel.network_project_stable_dumps(first, changed, plan.intent, 1) {
    Err(problem) => assert problem.message == "network observation changed between consecutive dumps"
    Ok(_) => assert false
  }
  var incomplete = first
  incomplete.state = "partial"
  match kernel.network_project_stable_dumps(incomplete, incomplete, plan.intent, 1) {
    Err(problem) => assert problem.message == "complete issue-free network observation required"
    Ok(_) => assert false
  }
}
