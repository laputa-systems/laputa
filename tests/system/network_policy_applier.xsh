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
== an injected concurrent change stops the pass before any mutation
conflict reobserve plans=4 attempts=0 reason=observation changed before operation 0
conflict-kept-old true
conflict-untouched-new true
conflict-concurrent true
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
NETWORK_APPLIER_OK
"""

test test_live_applier_converges_and_reports_conflicts_in_a_disposable_namespace [fs, process, env, error] { |ctx|
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
    }
    Err(failure) => test.skip(f"the kernel refuses a private user and network namespace: {failure.message}")
  }
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
