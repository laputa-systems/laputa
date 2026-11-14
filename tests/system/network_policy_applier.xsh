use packages.laputa-net.network_kernel as kernel
use packages.laputa-net.network_plan as policy
use lib.net_state

const expected_transcript = """== a refused operation keeps its managed address and asks for observation
refused reobserve plans=3 attempts=3 reason=operation 2 denied; partial state requires observation
refused-added-address true
refused-no-managed-route true
== a later reapplication converges and leaves foreign state alone
applied converged plans=1 attempts=1 owned=198.18.1.2/24|198.18.1.1:100
applied-address true
applied-route true
foreign-address true
peer-address true
foreign-route true
operator-route true
== a settled cohort plans nothing and mutates nothing
settled converged plans=0 attempts=0 owned=198.18.1.2/24|198.18.1.1:100
settled-total-addresses 3
settled-total-routes 16
== a second process changes kernel state between planning and application
writer-distinct true
conflict reobserve plans=4 attempts=0 reason=observation changed before operation 0
writer-completed true
conflict-kept-old true
conflict-untouched-new true
conflict-concurrent true
== a fresh observation converges after the separate writer and then plans nothing
recovered converged plans=2 attempts=2 owned=198.18.1.2/24|198.18.1.1:200
recovered-settled converged plans=0 attempts=0 owned=198.18.1.2/24|198.18.1.1:200
recovered-concurrent true
recovered-foreign-address true
recovered-peer-address true
recovered-foreign-route true
recovered-operator-route true
== a zero-metric route change is refused in both directions and mutates nothing
zero-add-operation true
zero-add-plan-refused a zero-metric default route is never created because the kernel treats priority 0 as unset on removal, so it could not be removed exactly
zero-removal-operation true
zero-removal-plan-refused a zero-metric default route cannot be removed exactly; the kernel treats a zero priority as a wildcard over every metric
zero-removal-refused a zero-metric default route cannot be removed exactly; the kernel treats a zero priority as a wildcard over every metric
zero-kept-operator-route true
zero-added-nothing true
== lost notifications require a full observation and mutate nothing
lost reobserve plans=3 attempts=0 reason=lost events require full observation
lost-untouched-new true
lost-kept-old true
== a customized selected default is refused before any change
customized-errno 0
customized-observed true
customized-projection refused selected default route carries unsupported attributes
customized-kept true
customized-added-nothing true
== IPv6: the packaged policy disables the stack, so the kernel refuses and the controller reports a denial
disabled6 reobserve plans=2 attempts=1 reason=operation 0 denied; partial state requires observation
disabled6-added-nothing true
disabled6-no-link-local true
== IPv6: static convergence leaves link-local, advertised, dynamic, operator and IPv4 state alone
dynamic6-errno 0
dynamic6-not-permanent true
applied6 converged plans=2 attempts=2 owned=2001:db8:1::2/64|2001:db8:1::1:100
applied6-address true
applied6-route true
applied6-settled true
foreign6-address true
peer6-address true
dynamic6-address true
link-local6-kept true
advertised6-route true
operator6-route true
foreign6-route true
ipv4-untouched true
== IPv6: a settled cohort plans nothing and mutates nothing
settled6 converged plans=0 attempts=0 owned=2001:db8:1::2/64|2001:db8:1::1:100
settled6-state-unchanged true
== IPv6: a second process changes kernel state between planning and application
writer6-distinct true
conflict6 reobserve plans=4 attempts=0 reason=observation changed before operation 0
writer6-completed true
conflict6-kept-old true
conflict6-untouched-new true
conflict6-concurrent true
== IPv6: a fresh observation converges to a link-local gateway and then plans nothing
recovered6 converged plans=2 attempts=2 owned=2001:db8:1::2/64|fe80::1:200
recovered6-settled converged plans=0 attempts=0 owned=2001:db8:1::2/64|fe80::1:200
recovered6-concurrent true
recovered6-foreign true
recovered6-advertised true
== IPv6: a zero metric means the kernel default 1024, and an advertised route at that metric is refused by the kernel
default6-occupied reobserve plans=2 attempts=1 reason=operation 0 denied; partial state requires observation
default6-advertised-kept true
default6-owned-kept true
default6 converged plans=2 attempts=2 owned=2001:db8:1::2/64|fe80::1:1024
default6-metric-1024 true
default6-retired-200 true
== IPv6: lost notifications require a full observation and mutate nothing
lost6 reobserve plans=2 attempts=0 reason=lost events require full observation
lost6-untouched-new true
lost6-kept-old true
== IPv6: a duplicate address fails detection and the next observation reports it
dup6-first-pass explicit-or-tentative
dup6-observation refused selected IPv6 address failed duplicate address detection
dup6-reconcile refused selected IPv6 address failed duplicate address detection
NETWORK_APPLIER_OK
"""

test test_live_applier_converges_and_reports_conflicts_in_a_disposable_namespace [fs, process, env, io, error] { |ctx|
  guard system.uname()?.sysname == "Linux" else {
    test.skip("route netlink is Linux-only")
    return
  }
  let root = env.get_or("XSH_ROOT", "")?
  if root == "" {
    test.skip("XSH_ROOT is required to run the applier fixture against the XSH core")
    return
  }
  let scratch = test.temp_dir(ctx, name: "network-applier")?
  let stdout = fp"{scratch}/stdout"
  let stderr = fp"{scratch}/stderr"
  let modules = f"{ctx.core_dir.parent}:{root}/core"
  let argv = [ctx.xsh_bin.display(), p"tests/system/fixtures/network-policy-applier.xsh".display(), "disposable-namespace"]
  let child_env = {XSH_MODULE_PATH: modules, LC_ALL: "C", XSH_EXECUTION_PHRASE: ""}
  let command = process.command_argv(ctx.xsh_bin, argv, p".", child_env, b"", stdout, stderr, timeout: 120s)
  match linux.run_in_namespaces(command, unshare: ["user", "net"], map_root_user: true) {
    Ok(status) => {
      let output = stdout.read_text()?
      assert status.shell_code()? == 0, f"{output}{stderr.read_text()?}"
      assert output == expected_transcript, output
      assert "NETWORK_WRITER_IDENTITIES controller=" in stderr.read_text()?
      assert " family=inet6" in stderr.read_text()?
      io.write_stdout(output)
      io.write_stderr(stderr.read_text()?)
    }
    Err(failure) => test.skip(f"the kernel refuses a private user and network namespace: {failure.message}")
  }
}

test test_separate_writer_refuses_to_run_outside_its_disposable_namespace [fs, process, error] { |ctx|
  let scratch = test.temp_dir(ctx, name: "network-writer-scope")?
  let stdout = fp"{scratch}/stdout"
  let stderr = fp"{scratch}/stderr"
  let namespace = p"unused"
  let argv = [ctx.xsh_bin.display(), p"tests/system/fixtures/network-policy-writer.xsh".display(), "host", scratch.display(), "0", "0", namespace.display()]
  let command = process.command_argv(ctx.xsh_bin, argv, p".", {}, b"", stdout, stderr, timeout: 10s)
  let status = process.run(command)?
  assert !status.ok
  assert "writer requires the disposable namespace fixture" in stderr.read_text()?
  assert !fp"{scratch}/ready".exists()?
}

test test_applier_refuses_to_run_outside_its_disposable_namespace [fs, process, env, error] { |ctx|
  let root = env.get_or("XSH_ROOT", "")?
  if root == "" {
    test.skip("XSH_ROOT is required to check the applier refusal")
    return
  }
  let scratch = test.temp_dir(ctx, name: "network-applier-scope")?
  let stdout = fp"{scratch}/stdout"
  let stderr = fp"{scratch}/stderr"
  let argv = [ctx.xsh_bin.display(), p"tests/system/fixtures/network-policy-applier.xsh".display(), "host"]
  let child_env = {XSH_MODULE_PATH: f"{ctx.core_dir.parent}:{root}/core", LC_ALL: "C"}
  let command = process.command_argv(ctx.xsh_bin, argv, p".", child_env, b"", stdout, stderr, timeout: 30s)
  let status = process.run(command)?
  assert status.shell_code()? != 0
  assert "run only inside the disposable namespace fixture" in stderr.read_text()?
}

test test_zero_metric_route_changes_never_reach_a_request [error] {
  let observed: policy.NetworkSnapshot = {
    sequence: 1, ifindex: 7, name: "veth-test", kind: "veth", up: true,
    addresses: [{local: "192.0.2.2", prefix: 24}],
    routes: [{gateway: "192.0.2.1", metric: 0}],
  }
  let owned: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [{local: "192.0.2.2", prefix: 24}], routes: [{gateway: "192.0.2.1", metric: 0}]}
  let raised: policy.NetworkIntent = {ifindex: 7, name: "veth-test", address: {local: "192.0.2.2", prefix: 24}, gateway: "192.0.2.1", metric: 200}
  let plan = policy.network_plan(raised, owned, observed)?
  assert plan.operations == [policy.NetworkAddDefaultRoute({gateway: "192.0.2.1", metric: 200}), policy.NetworkRemoveDefaultRoute({gateway: "192.0.2.1", metric: 0})]
  match kernel.network_changes(plan) {
    Err(problem) => assert problem.message == "a zero-metric default route cannot be removed exactly; the kernel treats a zero priority as a wildcard over every metric"
    Ok(_) => assert false, "a zero-metric removal was encoded"
  }
  assert kernel.network_change(plan, 0) == Ok(net_state.AddRoute({family: .Inet, table: net_state.TABLE_MAIN, destination: null, prefix: 0, source: null, source_prefix: 0, preferred_source: null, tos: 0, priority: 200, protocol: 3, scope: 0, route_type: 1, flags: 0, hops: [{ifindex: 7, gateway: "192.0.2.1"}], other_attributes: []}))
  match kernel.network_change(plan, 1) {
    Err(problem) => assert problem.message == "a zero-metric default route cannot be removed exactly; the kernel treats a zero priority as a wildcard over every metric"
    Ok(_) => assert false, "a zero-metric removal was encoded"
  }
  let created: policy.NetworkIntent = {...raised, metric: 0}
  let empty_routes: policy.NetworkSnapshot = {...observed, routes: []}
  let creation = policy.network_plan(created, {ifindex: 7, name: "veth-test", addresses: [{local: "192.0.2.2", prefix: 24}], routes: []}, empty_routes)?
  assert creation.operations == [policy.NetworkAddDefaultRoute({gateway: "192.0.2.1", metric: 0})]
  match kernel.network_change(creation, 0) {
    Err(problem) => assert problem.message == "a zero-metric default route is never created because the kernel treats priority 0 as unset on removal, so it could not be removed exactly"
    Ok(_) => assert false, "a zero-metric creation was encoded"
  }
}

test test_forged_operations_are_rejected_by_the_whole_change_set [error] {
  let intent: policy.NetworkIntent = {ifindex: 7, name: "veth-test", address: {local: "192.0.2.3", prefix: 24}, gateway: "192.0.2.1", metric: 100}
  let ownership: policy.NetworkOwnership = {ifindex: 7, name: "veth-test", addresses: [], routes: []}
  let observed: policy.NetworkSnapshot = {sequence: 1, ifindex: 7, name: "veth-test", kind: "veth", up: true, addresses: [], routes: []}
  let plan = policy.network_plan(intent, ownership, observed)?
  assert plan.operations.len() == 2
  let changes = kernel.network_changes(plan)?
  assert changes.len() == 2
  for index in range(changes.len()) {
    assert changes[index] == kernel.network_change(plan, index)?
  }
  var forged = plan
  forged.operations = [policy.NetworkRemoveAddress({local: "198.51.100.2", prefix: 24})]
  match kernel.network_changes(forged) {
    Err(problem) => assert problem.message == "operation is not part of a valid policy plan"
    Ok(_) => assert false, "a forged operation was accepted"
  }
  var extended = plan
  extended.operations = plan.operations + [policy.NetworkRemoveDefaultRoute({gateway: "198.51.100.1", metric: 200})]
  match kernel.network_changes(extended) {
    Err(problem) => assert problem.message == "operation is not part of a valid policy plan"
    Ok(_) => assert false, "an appended operation was accepted"
  }
}
