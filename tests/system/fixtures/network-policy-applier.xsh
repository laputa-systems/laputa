##! Live reconcile driver for the managed virtual-Ethernet cohort. Runs inside a
##! disposable user and network namespace and prints bounded transcripts that a
##! test compares as text. Nothing here is installed.
use lib.net_state
use lib.nettools_fixture as fixture
use packages.laputa-net.network_kernel as kernel
use packages.laputa-net.network_plan as policy

error NetworkApplierError = Failed(message: Str)

const managed = "lap-net0"
const peer = "lap-net1"
const foreign_address = "198.18.0.2"
const managed_address = "198.18.1.2"
const replacement_address = "198.18.2.2"
const reachable_gateway = "198.18.1.1"
const refused_gateway = "203.0.113.1"
const concurrent_address = "198.18.3.3"
const tainted_gateway = "198.19.0.1"
const peer_gateway = "198.19.0.1"

pure foreign_route(ifindex: Int) -> net_state.Route {
  {
    family: .Inet, table: net_state.TABLE_MAIN, destination: "100.64.0.0", prefix: 10, source: null,
    source_prefix: 0, preferred_source: null, tos: 0, priority: 5000, protocol: 4,
    scope: 0, route_type: 1, flags: 0, hops: [{ifindex, gateway: null}], other_attributes: [],
  }
}

pure operator_route(ifindex: Int) -> net_state.Route {
  {
    family: .Inet, table: net_state.TABLE_MAIN, destination: null, prefix: 0, source: null,
    source_prefix: 0, preferred_source: null, tos: 0, priority: 700, protocol: 4,
    scope: 0, route_type: 1, flags: 0, hops: [{ifindex, gateway: "198.19.0.1"}], other_attributes: [],
  }
}

pure attribute(kind: Int, data: Bytes) -> Bytes {
  let length = 4 + data.len()
  bytes.concat([bytes.pack_le(length, 2) ?? b"", bytes.pack_le(kind, 2) ?? b"", data, bytes.zero((4 - length % 4) % 4) ?? b""])
}

proc add_customized_default(ifindex: Int, gateway: Str, metric: Int, mtu: Int) [process, net, error] -> Result[Int, Error] {
  let c = linux.net_constants()
  let header = bytes.concat([bytes.from_ints([c.AF_INET, 0, 0, 0, 254, 3, 0, 1])?, bytes.zero(4)?])
  let raw = bytes.from_ints([octet as Int for octet in gateway.split(".")])?
  let payload = bytes.concat([header, attribute(c.RTA_GATEWAY, raw), attribute(c.RTA_OIF, bytes.pack_le(ifindex, 4)?), attribute(6, bytes.pack_le(metric, 4)?), attribute(8, attribute(2, bytes.pack_le(mtu, 4)?)), attribute(15, bytes.pack_le(254, 4)?)])
  let ack = linux.netlink_route_request(c.RTM_NEWROUTE, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK).bit_or(c.NLM_F_CREATE).bit_or(c.NLM_F_EXCL), payload, 1000)?
  Ok(ack.errno)
}

proc clear_managed_routes(ifindex: Int) [process, env, net, error] {
  let state = net_state.observe()?
  for route in state.routes {
    if route.family == .Inet and route.prefix == 0 and route.protocol == 3 and route.hops.len() == 1 and route.hops[0].ifindex == ifindex {
      net_state.apply(net_state.RemoveRoute(route))?
    }
  }
}

pure managed_route(ifindex: Int, gateway: Str, metric: Int) -> net_state.Route {
  {
    family: .Inet, table: net_state.TABLE_MAIN, destination: null, prefix: 0, source: null,
    source_prefix: 0, preferred_source: null, tos: 0, priority: metric, protocol: 3,
    scope: 0, route_type: 1, flags: 0, hops: [{ifindex, gateway}], other_attributes: [],
  }
}

pure intent(ifindex: Int, local: Str, gateway: Str, metric: Int) -> policy.NetworkIntent {
  {ifindex, name: managed, address: {local, prefix: 24}, gateway, metric}
}

pure ownership(ifindex: Int, addresses: List[policy.NetworkAddress], routes: List[policy.NetworkDefaultRoute]) -> policy.NetworkOwnership {
  {ifindex, name: managed, addresses, routes}
}

proc verdict(label: Str, reconcile: kernel.NetworkReconcile) [io] {
  match reconcile.result {
    policy.NetworkConverged(owned) => {
      var addresses: List[Str] = []
      for address in owned.addresses { addresses += [f"{address.local}/{address.prefix}"] }
      var routes: List[Str] = []
      for route in owned.routes { routes += [f"{route.gateway}:{route.metric}"] }
      print f"{label} converged plans={reconcile.plan.operations.len()} attempts={reconcile.attempts} owned={addresses.join(",")}|{routes.join(",")}"
    }
    policy.NetworkReobserve(reason) => print f"{label} reobserve plans={reconcile.plan.operations.len()} attempts={reconcile.attempts} reason={reason}"
    policy.NetworkInvalid(reason) => print f"{label} invalid plans={reconcile.plan.operations.len()} attempts={reconcile.attempts} reason={reason}"
  }
}

pure address_kept(state: net_state.State, ifindex: Int, local: Str) -> Bool {
  [address for address in net_state.addresses_of(state, ifindex) if address.local == local and address.family == .Inet].len() == 1
}

proc main(scope: Str) [fs, process, env, net, io, error] {
  if scope != "disposable-namespace" {
    return Err(NetworkApplierError.Failed("run only inside the disposable namespace fixture"))
  }
  fixture.link_add_veth(managed, peer, "02:00:00:00:32:01", "02:00:00:00:32:02")
  fixture.link_up(peer)
  let ifindex = fixture.index_of(managed)
  let peer_index = fixture.index_of(peer)
  fixture.address_add4(managed, foreign_address, 24, "198.18.0.255", "")
  fixture.address_add4(peer, "198.19.0.2", 24, "198.19.0.255", "")
  net_state.apply(net_state.AddRoute(foreign_route(peer_index)))?
  net_state.apply(net_state.AddRoute(operator_route(peer_index)))?

  print "== a refused operation keeps its managed address and asks for observation"
  let refused_intent = intent(ifindex, managed_address, refused_gateway, 100)
  let refused = kernel.network_reconcile(refused_intent, ownership(ifindex, [], []), 1)?
  verdict("refused", refused)
  let after_refusal = net_state.observe()?
  print f"refused-added-address {address_kept(after_refusal, ifindex, managed_address)}"
  print f"refused-no-managed-route {[route for route in after_refusal.routes if route.prefix == 0 and route.hops.len() == 1 and route.hops[0].ifindex == ifindex].is_empty()}"

  print "== a later reapplication converges and leaves foreign state alone"
  let desired = intent(ifindex, managed_address, reachable_gateway, 100)
  let owned_addresses = [{local: managed_address, prefix: 24}]
  let applied = kernel.network_reconcile(desired, ownership(ifindex, owned_addresses, []), 10)?
  verdict("applied", applied)
  let after_apply = net_state.observe()?
  print f"applied-address {address_kept(after_apply, ifindex, managed_address)}"
  print f"applied-route {managed_route(ifindex, reachable_gateway, 100) in after_apply.routes}"
  print f"foreign-address {address_kept(after_apply, ifindex, foreign_address)}"
  print f"peer-address {address_kept(after_apply, peer_index, "198.19.0.2")}"
  print f"foreign-route {foreign_route(peer_index) in after_apply.routes}"
  print f"operator-route {operator_route(peer_index) in after_apply.routes}"

  print "== a settled cohort plans nothing and mutates nothing"
  let settled = ownership(ifindex, owned_addresses, [{gateway: reachable_gateway, metric: 100}])
  let converged = kernel.network_reconcile(desired, settled, 20)?
  verdict("settled", converged)
  let after_settled = net_state.observe()?
  print f"settled-total-addresses {net_state.addresses_of(after_settled, ifindex).len()}"
  print f"settled-total-routes {after_settled.routes.len()}"

  print "== an injected concurrent change stops the pass before any mutation"
  let before_injection = kernel.network_observe(desired, 30)?
  let replacing = intent(ifindex, replacement_address, reachable_gateway, 200)
  let stale_plan = policy.network_plan(replacing, settled, before_injection)?
  net_state.apply(net_state.AddAddress({ifindex, family: .Inet, local: concurrent_address, prefix: 24, peer: null, broadcast: null, scope: 0, flags: 0}))?
  let notifications = net_state.subscribe()?
  defer unix.close_fd(notifications)
  let conflicted = kernel.network_apply_plan(stale_plan, notifications, 31)?
  verdict("conflict", conflicted)
  let after_conflict = net_state.observe()?
  print f"conflict-kept-old {address_kept(after_conflict, ifindex, managed_address)}"
  print f"conflict-untouched-new {!address_kept(after_conflict, ifindex, replacement_address)}"
  print f"conflict-concurrent {address_kept(after_conflict, ifindex, concurrent_address)}"

  print "== a zero-metric route change is refused in both directions and mutates nothing"
  let before_zero = kernel.network_observe(desired, 50)?
  let zero_desired = intent(ifindex, managed_address, reachable_gateway, 0)
  match policy.network_plan(zero_desired, settled, before_zero) {
    Ok(plan) => {
      print f"zero-add-operation {policy.NetworkAddDefaultRoute({gateway: reachable_gateway, metric: 0}) in plan.operations}"
      match kernel.network_changes(plan) {
        Ok(_) => print "zero-add encoded"
        Err(problem) => print f"zero-add-plan-refused {problem.message}"
      }
    }
    Err(problem) => print f"zero-add-policy-refused {problem.message}"
  }
  net_state.apply(net_state.RemoveRoute(managed_route(ifindex, reachable_gateway, 100)))?
  net_state.apply(net_state.AddRoute(managed_route(ifindex, reachable_gateway, 0)))?
  let operator_zero = kernel.network_observe(desired, 52)?
  let zero_owned = ownership(ifindex, owned_addresses, [{gateway: reachable_gateway, metric: 0}])
  let raise = intent(ifindex, managed_address, reachable_gateway, 200)
  let raise_plan = policy.network_plan(raise, zero_owned, operator_zero)?
  print f"zero-removal-operation {policy.NetworkRemoveDefaultRoute({gateway: reachable_gateway, metric: 0}) in raise_plan.operations}"
  match kernel.network_changes(raise_plan) {
    Ok(_) => print "zero-removal encoded"
    Err(problem) => print f"zero-removal-plan-refused {problem.message}"
  }
  match kernel.network_reconcile(raise, zero_owned, 53) {
    Ok(reconcile) => verdict("zero-removal", reconcile)
    Err(problem) => print f"zero-removal-refused {problem.message}"
  }
  let after_zero = net_state.observe()?
  print f"zero-kept-operator-route {managed_route(ifindex, reachable_gateway, 0) in after_zero.routes}"
  print f"zero-added-nothing {!(managed_route(ifindex, reachable_gateway, 200) in after_zero.routes)}"

  print "== lost notifications require a full observation and mutate nothing"
  let stable = kernel.network_observe(replacing, 40)?
  let planned = policy.network_plan(replacing, settled, stable)?
  let overrun = net_state.subscribe()?
  defer unix.close_fd(overrun)
  let c = linux.net_constants()
  linux.setsockopt_int(overrun, c.SOL_SOCKET, c.SO_RCVBUF, 1)?
  for index in range(64) {
    net_state.apply(net_state.AddAddress({ifindex, family: .Inet, local: f"10.1.{index}.1", prefix: 32, peer: null, broadcast: null, scope: 0, flags: 0}))?
  }
  let lost = kernel.network_apply_plan(planned, overrun, 41)?
  verdict("lost", lost)
  let after_lost = net_state.observe()?
  print f"lost-untouched-new {!address_kept(after_lost, ifindex, replacement_address)}"
  print f"lost-kept-old {address_kept(after_lost, ifindex, managed_address)}"
  print "== a customized selected default is refused before any change"
  clear_managed_routes(ifindex)?
  let tainted_errno = add_customized_default(ifindex, reachable_gateway, 250, 1400)?
  print f"customized-errno {tainted_errno}"
  let tainted_state = net_state.observe()?
  let tainted = [route for route in tainted_state.routes if route.family == .Inet and route.prefix == 0 and 8 in route.other_attributes]
  print f"customized-observed {tainted.len() == 1}"
  let tainted_intent = intent(ifindex, managed_address, reachable_gateway, 300)
  match kernel.network_observe(tainted_intent, 70) {
    Ok(_) => print "customized-projection accepted"
    Err(problem) => print f"customized-projection refused {problem.message}"
  }
  let after_tainted = net_state.observe()?
  let kept_tainted = [route for route in after_tainted.routes if route.family == .Inet and route.prefix == 0 and 8 in route.other_attributes]
  print f"customized-kept {kept_tainted.len() == 1}"
  print f"customized-added-nothing {!(managed_route(ifindex, reachable_gateway, 300) in after_tainted.routes)}"

  print "NETWORK_APPLIER_OK"
}
