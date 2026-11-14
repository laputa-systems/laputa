use packages.laputa-net.network_plan as policy
use tests.system.fixtures.network-policy-capture as capture

type NetworkVmFailureCapture = {kind: Str, input: policy.NetworkPlanInput, completed: Int, errno: Int, error: Str, observed: policy.NetworkSnapshot}

pure intent() -> policy.NetworkIntent {
  {ifindex: 7, name: "veth-test", address: {local: "192.0.2.2", prefix: 24}, gateway: "192.0.2.1", metric: 100}
}

pure snapshot() -> policy.NetworkSnapshot {
  {sequence: 1, ifindex: 7, name: "veth-test", kind: "veth", up: true,
    addresses: [{local: "192.0.2.2", prefix: 24}, {local: "198.51.100.2", prefix: 24}],
    routes: [{gateway: "192.0.2.1", metric: 100}, {gateway: "198.51.100.1", metric: 200}]}
}

pure owned() -> policy.NetworkOwnership {
  {ifindex: 7, name: "veth-test", addresses: [{local: "192.0.2.2", prefix: 24}], routes: [{gateway: "192.0.2.1", metric: 100}]}
}

test test_no_change_is_empty_and_foreign_resources_are_preserved [error] {
  let plan = policy.network_plan(intent(), owned(), snapshot())?
  assert plan.operations.is_empty()
  let empty: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [], routes: []}
  match policy.network_plan(intent(), empty, snapshot()) {
    Err(_) => {}
    Ok(_) => assert false
  }
}

test test_replay_rejects_operations_outside_the_policy [error] {
  var plan = policy.network_plan(intent(), owned(), snapshot())?
  plan.operations = [policy.NetworkRemoveAddress({local: "198.51.100.2", prefix: 24})]
  assert policy.network_replay(plan, [policy.NetworkPrecondition(snapshot())]) == policy.NetworkInvalid("plan operations do not match policy")
}

test test_changed_address_removes_only_owned_resources [error] {
  var desired = intent()
  desired.address = {local: "192.0.2.3", prefix: 24}
  let plan = policy.network_plan(desired, owned(), snapshot())?
  assert plan.operations == [policy.NetworkAddAddress(desired.address), policy.NetworkRemoveAddress(intent().address)]
  var observed = snapshot()
  observed.sequence = 2
  observed.addresses = [desired.address, {local: "198.51.100.2", prefix: 24}]
  let next_owned: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [desired.address], routes: owned().routes}
  let next = policy.network_plan(desired, next_owned, observed)?
  assert next.operations.is_empty()
}

test test_replay_requires_fresh_observation_after_failed_operation [error] {
  var desired = intent()
  desired.address = {local: "192.0.2.3", prefix: 24}
  let plan = policy.network_plan(desired, owned(), snapshot())?
  let events = [policy.NetworkPrecondition(snapshot()), policy.NetworkDenied(0)]
  let first = policy.network_replay(plan, events)
  assert first == policy.network_replay(plan, events)
  assert first == policy.NetworkReobserve("operation 0 denied; partial state requires observation")
}

test test_stale_lost_missing_and_reordered_observations_fail_closed [error] {
  var desired = intent()
  desired.address = {local: "192.0.2.3", prefix: 24}
  let plan = policy.network_plan(desired, owned(), snapshot())?
  var stale = snapshot()
  stale.up = false
  assert policy.network_replay(plan, [policy.NetworkPrecondition(stale)]) == policy.NetworkReobserve("stale precondition")
  assert policy.network_replay(plan, [policy.NetworkLostEvents]) == policy.NetworkReobserve("lost events require full observation")
  assert policy.network_replay(plan, []) == policy.NetworkInvalid("missing precondition observation")
  assert policy.network_replay(plan, [policy.NetworkApplied(0)]) == policy.NetworkInvalid("expected precondition observation")
  assert policy.network_replay(plan, [policy.NetworkPrecondition(snapshot()), policy.NetworkApplied(1)]) == policy.NetworkInvalid("operation result out of order")
  assert policy.network_replay(plan, [policy.NetworkPrecondition(snapshot()), policy.NetworkTruncated]) == policy.NetworkInvalid("truncated observation")
  var fresh = snapshot()
  fresh.sequence = 2
  assert policy.network_replay(plan, [policy.NetworkPrecondition(snapshot()), policy.NetworkApplied(0), policy.NetworkObserved(fresh)]) == policy.NetworkInvalid("missing operation results")
}

test test_acknowledged_changes_need_new_complete_observation [error] {
  var desired = intent()
  desired.address = {local: "192.0.2.3", prefix: 24}
  let plan = policy.network_plan(desired, owned(), snapshot())?
  let prefix = [policy.NetworkPrecondition(snapshot()), policy.NetworkApplied(0), policy.NetworkApplied(1)]
  assert policy.network_replay(plan, prefix) == policy.NetworkInvalid("missing final observation")
  var observed = snapshot()
  observed.sequence = 2
  match policy.network_replay(plan, prefix + [policy.NetworkObserved(observed)]) {
    policy.NetworkReobserve(reason) => assert reason == "operations acknowledged but state has not converged"
    policy.NetworkInvalid(reason) => assert reason == "expected re-observation"
    policy.NetworkConverged(_) => assert false
  }
  observed.addresses = [desired.address, {local: "198.51.100.2", prefix: 24}]
  let expected: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [desired.address], routes: owned().routes}
  assert policy.network_replay(plan, prefix + [policy.NetworkObserved(observed)]) == policy.NetworkConverged(expected)
  observed.addresses = [desired.address]
  assert policy.network_replay(plan, prefix + [policy.NetworkObserved(observed)]) == policy.NetworkReobserve("foreign address disappeared")
}

test test_owned_resources_are_bound_to_link_and_mixed_families_are_rejected [error] {
  var wrong_owner = owned()
  wrong_owner.ifindex = 8
  match policy.network_plan(intent(), wrong_owner, snapshot()) {
    Err(_) => {}
    Ok(_) => assert false
  }
  var desired = intent()
  desired.address.local = "2001:db8::2"
  match policy.network_plan(desired, owned(), snapshot()) {
    Err(_) => {}
    Ok(_) => assert false
  }
}

test test_offline_fixture_replays_deterministically_and_truncation_fails [fs, error] {
  let raw = p"tests/system/fixtures/network-policy-conflict.json".read_text()?
  let input: policy.NetworkPlanInput = json.decode(raw)?.require()?
  let first = policy.network_plan(input.intent, input.owned, input.observed)?
  assert first == policy.network_plan(input.intent, input.owned, input.observed)?
  let events = [policy.NetworkPrecondition(input.observed), policy.NetworkApplied(0), policy.NetworkDenied(1)]
  assert policy.network_replay(first, events) == policy.NetworkReobserve("operation 1 denied; partial state requires observation")
  match json.decode(raw.byte_slice(0, 50)) {
    Err(_) => {}
    Ok(_) => assert false
  }
}

test test_captured_docker_observation_reproduces_foreign_ownership_conflict [fs, error] {
  let raw = p"tests/system/fixtures/network-policy-docker-conflict.json".read_text()?
  let record: capture.NetworkConflictCapture = json.decode(raw)?.require()?
  assert record.error == "desired address is foreign; ownership cannot be inferred"
  assert record.input.owned.addresses.is_empty()
  assert record.input.owned.routes.is_empty()
  for attempt in [1, 2] {
    match policy.network_plan(record.input.intent, record.input.owned, record.input.observed) {
      Err(problem) => assert problem.message == record.error
      Ok(_) => assert false
    }
  }
}

test test_vm_capture_replays_partial_failure_without_rollback_or_foreign_adoption [fs, error] {
  let raw = policy.network_read_input(p"tests/system/fixtures/network-policy-vm-failure.json")?
  let record: NetworkVmFailureCapture = json.decode(raw)?.require()?
  assert record.kind == "network-operation-failure"
  assert record.errno == 101, record.error
  assert record.completed == 1
  assert record.input.observed.routes.is_empty()
  assert record.observed.routes.is_empty()
  assert record.observed.sequence > record.input.observed.sequence
  let plan = policy.network_plan(record.input.intent, record.input.owned, record.input.observed)?
  assert plan == policy.network_plan(record.input.intent, record.input.owned, record.input.observed)?
  assert plan.operations == [policy.NetworkAddAddress(record.input.intent.address), policy.NetworkAddDefaultRoute({gateway: record.input.intent.gateway, metric: record.input.intent.metric})]
  let events = [policy.NetworkPrecondition(record.input.observed), policy.NetworkApplied(0), policy.NetworkFailed(1)]
  let replayed = policy.network_replay(plan, events)
  assert replayed == policy.NetworkReobserve("operation 1 failed; partial state requires observation")
  assert replayed == policy.network_replay(plan, events)
  assert record.input.intent.address in record.observed.addresses
  for foreign in record.input.observed.addresses {
    assert foreign in record.observed.addresses
  }
  match policy.network_plan(record.input.intent, record.input.owned, record.observed) {
    Err(problem) => assert problem.message == "desired address is foreign; ownership cannot be inferred"
    Ok(_) => assert false
  }
}

pure docker_dump(tos: Int) -> LinuxNetworkDump {
  let link: LinuxNetworkLink = {address: null, attributes: [], broadcast: null, flags: 1, hardware_type: 1, ifindex: 2, kind: "veth", lower_ifindex: null, master_ifindex: null, mtu: 1500, name: "eth0", name_bytes: null, operstate: 6, rx_bytes: 0, tx_bytes: 0}
  let address: LinuxNetworkAddress = {address: "172.17.0.2", attributes: [], broadcast: "172.17.255.255", family: "inet", flags: 0, ifindex: 2, label: null, local: "172.17.0.2", preferred_lifetime_seconds: null, prefix_length: 16, scope: 0, valid_lifetime_seconds: null}
  let route: LinuxNetworkRoute = {attributes: [], destination: null, destination_prefix_length: 0, family: "inet", flags: 0, gateway: "172.17.0.1", input_ifindex: null, nexthops: [], output_ifindex: 2, preferred_source: null, priority: null, protocol: 3, route_type: 1, scope: 0, source: null, source_prefix_length: 0, table: 254, tos}
  {state: "complete", enumeration_succeeded: true, issues: [], links: [link], addresses: [address], routes: [route], rules: []}
}

test test_capture_selection_accepts_ordinary_default_and_refuses_tos_specific_default [error] {
  let record = capture.select_capture(docker_dump(0))?
  assert record.error == "desired address is foreign; ownership cannot be inferred"
  assert record.input.observed.routes == [{gateway: "172.17.0.1", metric: 0}]
  match capture.select_capture(docker_dump(8)) {
    Err(problem) => assert problem.message == "selected route is outside the supported main-table unicast cohort"
    Ok(_) => assert false
  }
}

pure intent6() -> policy.NetworkIntent {
  {ifindex: 7, name: "veth-test", address: {local: "2001:db8:1::2", prefix: 64}, gateway: "fe80::1", metric: 0}
}

pure snapshot6() -> policy.NetworkSnapshot {
  {sequence: 1, ifindex: 7, name: "veth-test", kind: "veth", up: true,
    addresses: [{local: "2001:db8:1::2", prefix: 64}, {local: "2001:db8:ff::2", prefix: 64}],
    routes: [{gateway: "fe80::1", metric: 1024}, {gateway: "2001:db8:ff::1", metric: 2048}]}
}

pure owned6() -> policy.NetworkOwnership {
  {ifindex: 7, name: "veth-test", addresses: [{local: "2001:db8:1::2", prefix: 64}], routes: [{gateway: "fe80::1", metric: 1024}]}
}

pure empty_owned() -> policy.NetworkOwnership {
  {ifindex: 7, name: "veth-test", addresses: [], routes: []}
}

test test_ipv6_plan_brings_the_link_up_and_uses_the_kernel_default_metric [error] {
  let observed: policy.NetworkSnapshot = {...snapshot6(), up: false, addresses: [], routes: []}
  let plan = policy.network_plan(intent6(), empty_owned(), observed)?
  assert plan.operations == [
    policy.NetworkBringLinkUp,
    policy.NetworkAddAddress({local: "2001:db8:1::2", prefix: 64}),
    policy.NetworkAddDefaultRoute({gateway: "fe80::1", metric: 1024}),
  ]
  var explicit = intent6()
  explicit.metric = 1024
  assert policy.network_plan(explicit, empty_owned(), observed)?.operations == plan.operations
  var chosen = intent6()
  chosen.metric = 300
  let other = policy.network_plan(chosen, empty_owned(), observed)?
  assert other.operations[2] == policy.NetworkAddDefaultRoute({gateway: "fe80::1", metric: 300})
}

test test_ipv4_zero_metric_is_not_rewritten_to_the_ipv6_default [error] {
  var zero = intent()
  zero.metric = 0
  let observed: policy.NetworkSnapshot = {...snapshot(), addresses: [], routes: []}
  let empty: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [], routes: []}
  let plan = policy.network_plan(zero, empty, observed)?
  assert plan.operations == [policy.NetworkAddAddress(zero.address), policy.NetworkAddDefaultRoute({gateway: "192.0.2.1", metric: 0})]
}

test test_ipv6_settled_cohort_plans_nothing_and_keeps_foreign_resources [error] {
  let plan = policy.network_plan(intent6(), owned6(), snapshot6())?
  assert plan.operations.is_empty()
  match policy.network_plan(intent6(), empty_owned(), snapshot6()) {
    Err(problem) => assert problem.message == "desired address is foreign; ownership cannot be inferred"
    Ok(_) => assert false
  }
  var without_address = snapshot6()
  without_address.addresses = [{local: "2001:db8:ff::2", prefix: 64}]
  match policy.network_plan(intent6(), empty_owned(), without_address) {
    Err(problem) => assert problem.message == "desired route is foreign; ownership cannot be inferred"
    Ok(_) => assert false
  }
}

test test_ipv6_retargeting_removes_only_owned_resources [error] {
  var desired = intent6()
  desired.address = {local: "2001:db8:1::3", prefix: 64}
  desired.gateway = "2001:db8:1::1"
  desired.metric = 200
  let plan = policy.network_plan(desired, owned6(), snapshot6())?
  assert plan.operations == [
    policy.NetworkAddAddress({local: "2001:db8:1::3", prefix: 64}),
    policy.NetworkAddDefaultRoute({gateway: "2001:db8:1::1", metric: 200}),
    policy.NetworkRemoveDefaultRoute({gateway: "fe80::1", metric: 1024}),
    policy.NetworkRemoveAddress({local: "2001:db8:1::2", prefix: 64}),
  ]
}

test test_ipv6_intent_must_be_canonical_global_unicast_text [error] {
  let observed: policy.NetworkSnapshot = {...snapshot6(), addresses: [], routes: []}
  let invalid = [
    "2001:DB8::2", "2001:0db8::2", "2001:db8:0:0:0:0:0:2", "2001:db8::0:2", "2001:db8:0:0:1::1", "2001:db8::1:1:1:1:1",
    "::", "::1", "::2", "fe80::2", "febf::2", "ff02::1", "::ffff:192.0.2.1", "::ffff:c000:201", "2001:db8::2::3",
    "2001:db8:1", "12345::1", "2001:db8::g", ":2001:db8::1", "2001:db8::1:", "2001:db8:1:2:3:4:5:6:7", "2001:db8::2%eth0",
  ]
  for text in invalid {
    var desired = intent6()
    desired.address.local = text
    match policy.network_plan(desired, empty_owned(), observed) {
      Err(problem) => assert problem.message == "invalid IPv6 intent or observation sequence", text
      Ok(_) => assert false, f"{text} was accepted"
    }
  }
  for text in ["2001:db8::2", "2001:db8:0:1:1:1:1:1", "2001:db8::1:0:0:1", "2001:db8::", "3fff::1", "fec0::1", "2000::1"] {
    var desired = intent6()
    desired.address.local = text
    let plan = policy.network_plan(desired, empty_owned(), observed)?
    assert policy.NetworkAddAddress(desired.address) in plan.operations, text
  }
}

test test_ipv6_prefix_and_gateway_bounds_and_family_agreement [error] {
  let observed: policy.NetworkSnapshot = {...snapshot6(), addresses: [], routes: []}
  for prefix in [0, 129, -1] {
    var desired = intent6()
    desired.address.prefix = prefix
    match policy.network_plan(desired, empty_owned(), observed) {
      Err(problem) => assert problem.message == "invalid IPv6 intent or observation sequence"
      Ok(_) => assert false, f"prefix {prefix} was accepted"
    }
  }
  for prefix in [1, 64, 128] {
    var desired = intent6()
    desired.address.prefix = prefix
    let _ = policy.network_plan(desired, empty_owned(), observed)?
  }
  for gateway in ["::", "::1", "ff02::1", "192.0.2.1", "FE80::1", "fe80:0:0:0:0:0:0:1", "fe80::1%eth0", ""] {
    var desired = intent6()
    desired.gateway = gateway
    match policy.network_plan(desired, empty_owned(), observed) {
      Err(problem) => assert problem.message == "invalid IPv6 intent or observation sequence", gateway
      Ok(_) => assert false, f"gateway {gateway} was accepted"
    }
  }
  for gateway in ["fe80::1", "2001:db8:1::1", "fe80::ff:fe00:3201"] {
    var desired = intent6()
    desired.gateway = gateway
    let _ = policy.network_plan(desired, empty_owned(), observed)?
  }
  var v4_with_v6_gateway = intent()
  v4_with_v6_gateway.gateway = "fe80::1"
  match policy.network_plan(v4_with_v6_gateway, owned(), snapshot()) {
    Err(problem) => assert problem.message == "invalid IPv4 intent or observation sequence"
    Ok(_) => assert false
  }
}

test test_a_cohort_never_mixes_address_families [error] {
  match policy.network_plan(intent6(), empty_owned(), snapshot()) {
    Err(problem) => assert problem.message == "observed cohort holds an address outside the intent's IPv6 family"
    Ok(_) => assert false
  }
  var only_route: policy.NetworkSnapshot = {...snapshot6(), addresses: [], routes: [{gateway: "192.0.2.1", metric: 100}]}
  match policy.network_plan(intent6(), empty_owned(), only_route) {
    Err(problem) => assert problem.message == "observed cohort holds a default route outside the intent's IPv6 family"
    Ok(_) => assert false
  }
  match policy.network_plan(intent6(), owned(), snapshot6()) {
    Err(problem) => assert problem.message == "ownership holds an address outside the intent's IPv6 family"
    Ok(_) => assert false
  }
  let route_only: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [], routes: [{gateway: "192.0.2.1", metric: 100}]}
  match policy.network_plan(intent6(), route_only, snapshot6()) {
    Err(problem) => assert problem.message == "ownership holds a default route outside the intent's IPv6 family"
    Ok(_) => assert false
  }
  match policy.network_plan(intent(), owned6(), snapshot()) {
    Err(problem) => assert problem.message == "ownership holds an address outside the intent's IPv4 family"
    Ok(_) => assert false
  }
  match policy.network_plan(intent(), owned(), snapshot6()) {
    Err(problem) => assert problem.message == "observed cohort holds an address outside the intent's IPv4 family"
    Ok(_) => assert false
  }
}

test test_ipv6_address_present_with_another_prefix_is_refused_before_a_kernel_collision [error] {
  var observed = snapshot6()
  observed.addresses = [{local: "2001:db8:1::2", prefix: 128}]
  observed.routes = []
  match policy.network_plan(intent6(), empty_owned(), observed) {
    Err(problem) => assert problem.message == "desired IPv6 address is present with another prefix; explicit reconciliation required"
    Ok(_) => assert false
  }
}

test test_ipv6_default_route_metric_occupancy_is_per_family [error] {
  var observed = snapshot6()
  observed.routes = [{gateway: "fe80::9", metric: 1024}]
  match policy.network_plan(intent6(), owned6(), observed) {
    Err(problem) => assert problem.message == "default route metric is occupied; explicit reconciliation required"
    Ok(_) => assert false
  }
  observed.routes = [{gateway: "fe80::9", metric: 100}]
  let plan = policy.network_plan(intent6(), owned6(), observed)?
  assert plan.operations == [policy.NetworkAddDefaultRoute({gateway: "fe80::1", metric: 1024})]
}

test test_ipv6_replay_converges_with_the_kernel_metric_and_catches_foreign_loss [error] {
  var desired = intent6()
  desired.address = {local: "2001:db8:1::3", prefix: 64}
  let plan = policy.network_plan(desired, owned6(), snapshot6())?
  assert plan.operations == [policy.NetworkAddAddress({local: "2001:db8:1::3", prefix: 64}), policy.NetworkRemoveAddress({local: "2001:db8:1::2", prefix: 64})]
  let prefix = [policy.NetworkPrecondition(snapshot6()), policy.NetworkApplied(0), policy.NetworkApplied(1)]
  var observed = snapshot6()
  observed.sequence = 2
  observed.addresses = [{local: "2001:db8:1::3", prefix: 64}, {local: "2001:db8:ff::2", prefix: 64}]
  let expected: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [{local: "2001:db8:1::3", prefix: 64}], routes: [{gateway: "fe80::1", metric: 1024}]}
  assert policy.network_replay(plan, prefix + [policy.NetworkObserved(observed)]) == policy.NetworkConverged(expected)
  var lost_foreign = observed
  lost_foreign.routes = [{gateway: "fe80::1", metric: 1024}]
  assert policy.network_replay(plan, prefix + [policy.NetworkObserved(lost_foreign)]) == policy.NetworkReobserve("foreign route disappeared")
  var retained = observed
  retained.addresses = [{local: "2001:db8:1::2", prefix: 64}, {local: "2001:db8:1::3", prefix: 64}, {local: "2001:db8:ff::2", prefix: 64}]
  assert policy.network_replay(plan, prefix + [policy.NetworkObserved(retained)]) == policy.NetworkReobserve("retired owned address remains")
  assert policy.network_replay(plan, [policy.NetworkPrecondition(snapshot())]) == policy.NetworkReobserve("stale precondition")
}

test test_ipv6_fixture_decodes_exactly_and_plans_without_touching_foreign_state [fs, error] {
  let raw = policy.network_read_input(p"tests/system/fixtures/network-policy-ipv6.json")?
  let input = policy.network_decode_input(raw)?
  let plan = policy.network_plan(input.intent, input.owned, input.observed)?
  assert plan.operations == [
    policy.NetworkAddAddress({local: "2001:db8:1::3", prefix: 64}),
    policy.NetworkAddDefaultRoute({gateway: "fe80::1", metric: 1024}),
    policy.NetworkRemoveDefaultRoute({gateway: "2001:db8:1::1", metric: 300}),
    policy.NetworkRemoveAddress({local: "2001:db8:1::2", prefix: 64}),
  ]
  assert policy.network_plan(input.intent, input.owned, input.observed)? == plan
  match json.decode(raw.byte_slice(0, 400)) {
    Err(_) => {}
    Ok(_) => assert false
  }
}
