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

test test_owned_resources_are_bound_to_link_and_ipv6_is_rejected [error] {
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
