##! Live reconcile driver for the managed virtual-Ethernet cohort, IPv4 and IPv6. Runs inside a
##! disposable user and network namespace and prints bounded transcripts that a
##! test compares as text. Nothing here is installed.
use lib.net_state
use lib.nettools
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
const managed6_address = "2001:db8:1::2"
const replacement6_address = "2001:db8:2::2"
const concurrent6_address = "2001:db8:3::3"
const dynamic6_address = "2001:db8:5::5"
const duplicate6_address = "2001:db8:7::7"
const foreign6_address = "2001:db8:ff::2"
const peer6_address = "2001:db8:19::2"
const global6_gateway = "2001:db8:1::1"
const link6_gateway = "fe80::1"
const advertised6_gateway = "fe80::aa"
const operator6_gateway = "fe80::2"

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

pure route6(ifindex: Int, destination: Str?, prefix: Int, gateway: Str?, metric: Int, protocol: Int) -> net_state.Route {
  {
    family: .Inet6, table: net_state.TABLE_MAIN, destination, prefix, source: null,
    source_prefix: 0, preferred_source: null, tos: 0, priority: metric, protocol,
    scope: 0, route_type: 1, flags: 0, hops: [{ifindex, gateway}], other_attributes: [],
  }
}

pure address6(ifindex: Int, local: Str, prefix: Int) -> net_state.Address {
  {ifindex, family: .Inet6, local, prefix, peer: null, broadcast: null, scope: 0, flags: 0}
}

pure intent6(ifindex: Int, local: Str, gateway: Str, metric: Int) -> policy.NetworkIntent {
  {ifindex, name: managed, address: {local, prefix: 64}, gateway, metric}
}

pure v6_view(state: net_state.State) -> List[Str] {
  let addresses = [f"{a.ifindex}:{a.local}/{a.prefix}" for a in state.addresses if a.family == .Inet6]
  let routes = [f"{r.table}:{r.destination ?? "default"}/{r.prefix}:{r.hops[0].gateway ?? "-"}@{r.hops[0].ifindex ?? 0}:{r.priority}:{r.protocol}:{r.route_type}" for r in state.routes if r.family == .Inet6]
  [@addresses, @routes] |> sort
}

pure has_route6(state: net_state.State, wanted: net_state.Route) -> Bool {
  [route for route in state.routes if route.family == .Inet6 and {...route, other_attributes: []} == wanted].len() == 1
}

pure address6_kept(state: net_state.State, ifindex: Int, local: Str) -> Bool {
  [address for address in net_state.addresses_of(state, ifindex) if address.local == local and address.family == .Inet6].len() == 1
}

pure duplicate_detection_failed(state: net_state.State, ifindex: Int, local: Str) -> Bool {
  [address for address in net_state.addresses_of(state, ifindex) if address.family == .Inet6 and address.local == local and address.flags.bit_and(8) != 0].len() == 1
}

pure ipv6_settled(state: net_state.State) -> Bool {
  [address for address in state.addresses if address.family == .Inet6 and address.flags.bit_and(64) != 0].is_empty()
}

pure link_local_count(state: net_state.State, ifindex: Int) -> Int {
  [address for address in net_state.addresses_of(state, ifindex) if address.family == .Inet6 and address.scope == 253].len()
}

proc add_dynamic_address6(ifindex: Int, local: Str, prefix: Int) [process, net, error] -> Result[Int, Error] {
  let c = linux.net_constants()
  guard let raw = nettools.ipv6_parse(local) else { return Err(NetworkApplierError.Failed(f"{local} is not an IPv6 address")) }
  let cacheinfo = bytes.concat([bytes.pack_le(1800, 4)?, bytes.pack_le(3600, 4)?, bytes.zero(8)?])
  let header = bytes.concat([bytes.from_ints([c.AF_INET6, prefix, 0, 0])?, bytes.pack_le(ifindex, 4)?])
  let payload = bytes.concat([header, attribute(c.IFA_ADDRESS, raw), attribute(6, cacheinfo)])
  let ack = linux.netlink_route_request(c.RTM_NEWADDR, c.NLM_F_REQUEST.bit_or(c.NLM_F_ACK).bit_or(c.NLM_F_CREATE).bit_or(c.NLM_F_EXCL), payload, 1000)?
  Ok(ack.errno)
}

proc set_ipv6_sysctl(link: Str, name: Str, value: Str) [fs, error] {
  fp"/proc/sys/net/ipv6/conf/{link}/{name}".write(value)
}

proc stale_ipv6_plan_is_refused(scope: Str, ifindex: Int, stale_plan: policy.NetworkPlan) [fs, process, env, net, io, time, error] {
  let notifications = net_state.subscribe()?
  defer unix.close_fd(notifications)
  tempdir barrier {
    let xsh = process.which("xsh")?
    let writer_source = path.absolute(p"tests/system/fixtures/network-policy-writer.xsh")?
    let controller = process.current_pid()?
    let namespace = p"/proc/self/ns/net".readlink()?
    let writer = spawn process.command_argv(xsh, [xsh.display(), writer_source.display(), scope, barrier.display(), f"{ifindex}", f"{controller}", namespace.display(), "inet6"], timeout: 15s)?
    defer writer.cancel(signal: "TERM", kill_after: 1s)
    wait until fp"{barrier}/ready".exists()? within 5s every 10ms
    assert fp"{barrier}/ready".read_text()?.parse_int()? == writer.pid
    assert writer.pid != controller
    fp"{barrier}/mutate".write_atomic("ready")
    wait until fp"{barrier}/changed".exists()? within 5s every 10ms
    assert fp"{barrier}/changed".read_text()?.parse_int()? == writer.pid
    assert address6_kept(net_state.observe()?, ifindex, concurrent6_address)
    eprint f"NETWORK_WRITER_IDENTITIES controller={controller} writer={writer.pid} namespace={namespace} family=inet6"
    print f"writer6-distinct {writer.pid != controller}"
    let conflicted = kernel.network_apply_plan(stale_plan, notifications, 91)?
    verdict("conflict6", conflicted)
    assert conflicted.attempts == 0
    assert conflicted.result == policy.NetworkReobserve("observation changed before operation 0")
    fp"{barrier}/release".write_atomic("ready")
    let status = wait writer ?
    assert status.exited_with(0), "separate IPv6 kernel writer failed"
    print f"writer6-completed {status.exited_with(0)}"
  }
}

proc ipv6_cohort(ifindex: Int, peer_index: Int) [fs, process, env, net, io, time, error] {
  let scope = "disposable-namespace"
  print "== IPv6: the packaged policy disables the stack, so the kernel refuses and the controller reports a denial"
  set_ipv6_sysctl(managed, "disable_ipv6", "1")?
  let disabled_intent = intent6(ifindex, managed6_address, global6_gateway, 100)
  let disabled = kernel.network_reconcile(disabled_intent, ownership(ifindex, [], []), 100)?
  verdict("disabled6", disabled)
  let after_disabled = net_state.observe()?
  print f"disabled6-added-nothing {!address6_kept(after_disabled, ifindex, managed6_address)}"
  print f"disabled6-no-link-local {link_local_count(after_disabled, ifindex) == 0}"
  set_ipv6_sysctl(managed, "disable_ipv6", "0")?

  print "== IPv6: static convergence leaves link-local, advertised, dynamic, operator and IPv4 state alone"
  fixture.address_add6(managed, foreign6_address, 64)
  fixture.address_add6(peer, peer6_address, 64)
  net_state.apply(net_state.AddRoute(route6(peer_index, "2001:db8:77::", 64, null, 5000, 4)))?
  net_state.apply(net_state.AddRoute(route6(peer_index, null, 0, operator6_gateway, 700, 4)))?
  net_state.apply(net_state.AddRoute(route6(ifindex, null, 0, advertised6_gateway, 1024, 9)))?
  let dynamic_errno = add_dynamic_address6(ifindex, dynamic6_address, 64)?
  print f"dynamic6-errno {dynamic_errno}"
  let dynamic_flags = [address.flags for address in net_state.observe()?.addresses if address.local == dynamic6_address]
  print f"dynamic6-not-permanent {dynamic_flags.len() == 1 and dynamic_flags[0].bit_and(128) == 0}"
  let links_before = link_local_count(net_state.observe()?, ifindex)
  let desired = intent6(ifindex, managed6_address, global6_gateway, 100)
  let applied = kernel.network_reconcile(desired, ownership(ifindex, [], []), 110)?
  verdict("applied6", applied)
  wait until ipv6_settled(net_state.observe()?) within 15s every 100ms
  let after_apply = net_state.observe()?
  print f"applied6-address {address6_kept(after_apply, ifindex, managed6_address)}"
  print f"applied6-route {has_route6(after_apply, route6(ifindex, null, 0, global6_gateway, 100, 3))}"
  print f"applied6-settled {[address for address in after_apply.addresses if address.local == managed6_address and address.flags == 128].len() == 1}"
  print f"foreign6-address {address6_kept(after_apply, ifindex, foreign6_address)}"
  print f"peer6-address {address6_kept(after_apply, peer_index, peer6_address)}"
  print f"dynamic6-address {address6_kept(after_apply, ifindex, dynamic6_address)}"
  print f"link-local6-kept {link_local_count(after_apply, ifindex) == links_before and links_before > 0}"
  print f"advertised6-route {has_route6(after_apply, route6(ifindex, null, 0, advertised6_gateway, 1024, 9))}"
  print f"operator6-route {has_route6(after_apply, route6(peer_index, null, 0, operator6_gateway, 700, 4))}"
  print f"foreign6-route {has_route6(after_apply, route6(peer_index, "2001:db8:77::", 64, null, 5000, 4))}"
  print f"ipv4-untouched {address_kept(after_apply, ifindex, managed_address) and address_kept(after_apply, ifindex, foreign_address)}"

  print "== IPv6: a settled cohort plans nothing and mutates nothing"
  let settled6 = ownership(ifindex, [{local: managed6_address, prefix: 64}], [{gateway: global6_gateway, metric: 100}])
  let before_settled = v6_view(net_state.observe()?)
  let converged = kernel.network_reconcile(desired, settled6, 120)?
  verdict("settled6", converged)
  print f"settled6-state-unchanged {before_settled == v6_view(net_state.observe()?)}"

  print "== IPv6: a second process changes kernel state between planning and application"
  let before_injection = kernel.network_observe(desired, 130)?
  let replacing = intent6(ifindex, replacement6_address, global6_gateway, 200)
  let stale_plan = policy.network_plan(replacing, settled6, before_injection)?
  stale_ipv6_plan_is_refused(scope, ifindex, stale_plan)?
  let after_conflict = net_state.observe()?
  print f"conflict6-kept-old {address6_kept(after_conflict, ifindex, managed6_address)}"
  print f"conflict6-untouched-new {!address6_kept(after_conflict, ifindex, replacement6_address)}"
  print f"conflict6-concurrent {address6_kept(after_conflict, ifindex, concurrent6_address)}"

  print "== IPv6: a fresh observation converges to a link-local gateway and then plans nothing"
  let recovery = intent6(ifindex, managed6_address, link6_gateway, 200)
  let recovered = kernel.network_reconcile(recovery, settled6, 132)?
  verdict("recovered6", recovered)
  let recovery_owned = ownership(ifindex, [{local: managed6_address, prefix: 64}], [{gateway: link6_gateway, metric: 200}])
  assert recovered.result == policy.NetworkConverged(recovery_owned)
  let recovery_settled = kernel.network_reconcile(recovery, recovery_owned, 133)?
  verdict("recovered6-settled", recovery_settled)
  assert recovery_settled.attempts == 0 and recovery_settled.plan.operations.is_empty()
  let after_recovery = net_state.observe()?
  print f"recovered6-concurrent {address6_kept(after_recovery, ifindex, concurrent6_address)}"
  print f"recovered6-foreign {address6_kept(after_recovery, ifindex, foreign6_address)}"
  print f"recovered6-advertised {has_route6(after_recovery, route6(ifindex, null, 0, advertised6_gateway, 1024, 9))}"

  print "== IPv6: a zero metric means the kernel default 1024, and an advertised route at that metric is refused by the kernel"
  let kernel_default = intent6(ifindex, managed6_address, link6_gateway, 0)
  let occupied = kernel.network_reconcile(kernel_default, recovery_owned, 140)?
  verdict("default6-occupied", occupied)
  let after_occupied = net_state.observe()?
  print f"default6-advertised-kept {has_route6(after_occupied, route6(ifindex, null, 0, advertised6_gateway, 1024, 9))}"
  print f"default6-owned-kept {has_route6(after_occupied, route6(ifindex, null, 0, link6_gateway, 200, 3))}"
  net_state.apply(net_state.RemoveRoute(route6(ifindex, null, 0, advertised6_gateway, 1024, 9)))?
  let defaulted = kernel.network_reconcile(kernel_default, recovery_owned, 142)?
  verdict("default6", defaulted)
  let after_default = net_state.observe()?
  print f"default6-metric-1024 {has_route6(after_default, route6(ifindex, null, 0, link6_gateway, 1024, 3))}"
  print f"default6-retired-200 {!has_route6(after_default, route6(ifindex, null, 0, link6_gateway, 200, 3))}"

  print "== IPv6: lost notifications require a full observation and mutate nothing"
  let defaulted_owned = ownership(ifindex, [{local: managed6_address, prefix: 64}], [{gateway: link6_gateway, metric: 1024}])
  let stable = kernel.network_observe(kernel_default, 150)?
  let planned = policy.network_plan(intent6(ifindex, replacement6_address, link6_gateway, 0), defaulted_owned, stable)?
  let overrun = net_state.subscribe()?
  defer unix.close_fd(overrun)
  let c = linux.net_constants()
  linux.setsockopt_int(overrun, c.SOL_SOCKET, c.SO_RCVBUF, 1)?
  for index in range(40) {
    net_state.apply(net_state.AddAddress(address6(ifindex, f"2001:db8:{256 + index}::1", 128)))?
  }
  let lost = kernel.network_apply_plan(planned, overrun, 151)?
  verdict("lost6", lost)
  for index in range(40) {
    net_state.apply(net_state.RemoveAddress(address6(ifindex, f"2001:db8:{256 + index}::1", 128)))?
  }
  let after_lost = net_state.observe()?
  print f"lost6-untouched-new {!address6_kept(after_lost, ifindex, replacement6_address)}"
  print f"lost6-kept-old {address6_kept(after_lost, ifindex, managed6_address)}"

  print "== IPv6: a duplicate address fails detection and the next observation reports it"
  fixture.address_add6(peer, duplicate6_address, 64)
  wait until ipv6_settled(net_state.observe()?) within 15s every 100ms
  let duplicated = kernel.network_reconcile(intent6(ifindex, duplicate6_address, link6_gateway, 0), defaulted_owned, 160)
  match duplicated {
    Ok(reconcile) => {
      match reconcile.result {
        policy.NetworkConverged(_) => print "dup6-first-pass explicit-or-tentative"
        policy.NetworkReobserve(reason) => {
          assert "failed duplicate address detection" in reason, reason
          print "dup6-first-pass explicit-or-tentative"
        }
        policy.NetworkInvalid(reason) => assert false, reason
      }
    }
    Err(problem) => {
      assert "failed duplicate address detection" in problem.message, problem.message
      print "dup6-first-pass explicit-or-tentative"
    }
  }
  wait until duplicate_detection_failed(net_state.observe()?, ifindex, duplicate6_address) within 15s every 100ms
  match kernel.network_observe(intent6(ifindex, duplicate6_address, link6_gateway, 0), 161) {
    Ok(_) => print "dup6-observation accepted"
    Err(problem) => print f"dup6-observation refused {problem.message}"
  }
  match kernel.network_reconcile(intent6(ifindex, duplicate6_address, link6_gateway, 0), defaulted_owned, 162) {
    Ok(_) => print "dup6-reconcile accepted"
    Err(problem) => print f"dup6-reconcile refused {problem.message}"
  }
}

proc main(scope: Str) [fs, process, env, net, io, time, error] {
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

  print "== a second process changes kernel state between planning and application"
  let before_injection = kernel.network_observe(desired, 30)?
  let replacing = intent(ifindex, replacement_address, reachable_gateway, 200)
  let stale_plan = policy.network_plan(replacing, settled, before_injection)?
  let notifications = net_state.subscribe()?
  defer unix.close_fd(notifications)
  tempdir barrier {
    let xsh = process.which("xsh")?
    let writer_source = path.absolute(p"tests/system/fixtures/network-policy-writer.xsh")?
    let controller = process.current_pid()?
    let namespace = p"/proc/self/ns/net".readlink()?
    let writer = spawn process.command_argv(xsh, [xsh.display(), writer_source.display(), scope, barrier.display(), f"{ifindex}", f"{controller}", namespace.display()], timeout: 15s)?
    defer writer.cancel(signal: "TERM", kill_after: 1s)
    wait until fp"{barrier}/ready".exists()? within 5s every 10ms
    assert fp"{barrier}/ready".read_text()?.parse_int()? == writer.pid
    assert writer.pid != controller
    fp"{barrier}/mutate".write_atomic("ready")
    wait until fp"{barrier}/changed".exists()? within 5s every 10ms
    assert fp"{barrier}/changed".read_text()?.parse_int()? == writer.pid
    assert address_kept(net_state.observe()?, ifindex, concurrent_address)
    eprint f"NETWORK_WRITER_IDENTITIES controller={controller} writer={writer.pid} namespace={namespace}"
    print f"writer-distinct {writer.pid != controller}"
    let conflicted = kernel.network_apply_plan(stale_plan, notifications, 31)?
    verdict("conflict", conflicted)
    assert conflicted.attempts == 0
    assert conflicted.result == policy.NetworkReobserve("observation changed before operation 0")
    fp"{barrier}/release".write_atomic("ready")
    let status = wait writer ?
    assert status.exited_with(0), "separate kernel writer failed"
    print f"writer-completed {status.exited_with(0)}"
  }
  let after_conflict = net_state.observe()?
  print f"conflict-kept-old {address_kept(after_conflict, ifindex, managed_address)}"
  print f"conflict-untouched-new {!address_kept(after_conflict, ifindex, replacement_address)}"
  print f"conflict-concurrent {address_kept(after_conflict, ifindex, concurrent_address)}"

  print "== a fresh observation converges after the separate writer and then plans nothing"
  let recovery_intent = intent(ifindex, managed_address, reachable_gateway, 200)
  let recovered = kernel.network_reconcile(recovery_intent, settled, 32)?
  verdict("recovered", recovered)
  let recovery_owned = ownership(ifindex, owned_addresses, [{gateway: reachable_gateway, metric: 200}])
  assert recovered.result == policy.NetworkConverged(recovery_owned)
  let recovery_settled = kernel.network_reconcile(recovery_intent, recovery_owned, 33)?
  verdict("recovered-settled", recovery_settled)
  assert recovery_settled.attempts == 0 and recovery_settled.plan.operations.is_empty()
  let restored = kernel.network_reconcile(desired, recovery_owned, 34)?
  assert restored.result == policy.NetworkConverged(settled)
  let after_recovery = net_state.observe()?
  print f"recovered-concurrent {address_kept(after_recovery, ifindex, concurrent_address)}"
  print f"recovered-foreign-address {address_kept(after_recovery, ifindex, foreign_address)}"
  print f"recovered-peer-address {address_kept(after_recovery, peer_index, "198.19.0.2")}"
  print f"recovered-foreign-route {foreign_route(peer_index) in after_recovery.routes}"
  print f"recovered-operator-route {operator_route(peer_index) in after_recovery.routes}"

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

  ipv6_cohort(ifindex, peer_index)?
  print "NETWORK_APPLIER_OK"
}
