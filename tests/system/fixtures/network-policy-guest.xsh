use packages.laputa-net.network_plan as policy
use packages.laputa-net.network_kernel as kernel
use lib.nettools_fixture as fixture
use pm.generation

error NetworkGuestError = Failed(message: Str)

proc observed(intent: policy.NetworkIntent, sequence: Int) [process, error] -> Result[policy.NetworkSnapshot, Error] {
  kernel.network_project_dump(linux.network_dump()?, intent, sequence)
}

proc request(value: kernel.NetworkKernelRequest) [process, net, error] {
  let c = linux.net_constants()
  let channel = linux.netlink_open(c.NETLINK_ROUTE)?
  defer unix.close_fd(channel)
  linux.set_socket_timeout(channel, c.SO_RCVTIMEO, 1000)
  linux.set_socket_timeout(channel, c.SO_SNDTIMEO, 1000)
  let replies = linux.netlink_request(channel, value.message_type, value.flags, value.payload, 0, 1000)?
  if !replies.is_empty() { return Err(NetworkGuestError.Failed("fixture request returned unexpected data")) }
}

proc main(scope: Str) [fs, process, net, error] {
  if scope != "disposable-vm" or !p"/mnt/self-hosting/inputs/laputa".is_dir()? {
    return Err(NetworkGuestError.Failed("run only inside the disposable self-hosting proof VM"))
  }
  let cmdline = p"/proc/cmdline".read_text()?.trim().split(" ")
  if "LAPUTA_SELF_HOSTING=1" not in cmdline {
    return Err(NetworkGuestError.Failed("network mutation requires the disposable VM kernel marker"))
  }
  let receipt = generation.read_generation_receipt(p"/")?
  if receipt.profile.name != "qemu-self-hosting" {
    return Err(NetworkGuestError.Failed("network mutation requires the disposable VM generation receipt"))
  }
  let previous = linux.network_dump()?
  if !previous.enumeration_succeeded or !previous.issues.is_empty() {
    return Err(NetworkGuestError.Failed("cannot establish the pre-fixture link inventory"))
  }
  let previous_indices = [link.ifindex for link in previous.links]
  fixture.link_add_veth("lap-net0", "lap-net1", "02:00:00:00:31:01", "02:00:00:00:31:02")
  let created = linux.network_dump()?
  if !created.enumeration_succeeded or !created.issues.is_empty() {
    return Err(NetworkGuestError.Failed("cannot establish the created veth pair"))
  }
  let fresh = [link for link in created.links if link.ifindex not in previous_indices]
  if fresh.len() != 2 { return Err(NetworkGuestError.Failed("fixture did not create exactly two fresh endpoints")) }
  let selected = [link for link in fresh if link.name == "lap-net0" and link.kind == "veth"]
  if selected.len() != 1 { return Err(NetworkGuestError.Failed("created managed veth is absent or ambiguous")) }
  let selected_link = selected[0]
  let peers = [link for link in fresh if link.kind == "veth" and link.ifindex == selected_link.lower_ifindex and link.lower_ifindex == selected_link.ifindex]
  if peers.len() != 1 { return Err(NetworkGuestError.Failed("created veth peer identity is absent or ambiguous")) }
  if let peer_name = peers[0].name {
    fixture.link_up(peer_name)
  } else {
    return Err(NetworkGuestError.Failed("created veth peer has no observed name"))
  }
  fixture.link_up("lap-net0")
  fixture.address_add4("lap-net0", "198.18.0.2", 24, "198.18.0.255", "")
  let dump = linux.network_dump()?
  let links = [link for link in dump.links if link.name == "lap-net0"]
  if links.len() != 1 { return Err(NetworkGuestError.Failed("fixture veth was not observed")) }
  let intent: policy.NetworkIntent = {ifindex: links[0].ifindex, name: "lap-net0", address: {local: "198.18.1.3", prefix: 24}, gateway: "192.0.2.1", metric: 100}
  let owned: policy.NetworkOwnership = {ifindex: intent.ifindex, name: intent.name, addresses: [], routes: []}
  let before = observed(intent, 1)?
  assert before.routes.is_empty()
  let plan = policy.network_plan(intent, owned, before)?
  assert plan.operations == [policy.NetworkAddAddress(intent.address), policy.NetworkAddDefaultRoute({gateway: intent.gateway, metric: intent.metric})]
  let add_address = kernel.network_encode_operation(plan, 0)?
  let add_route = kernel.network_encode_operation(plan, 1)?
  assert add_address.message_type == linux.net_constants().RTM_NEWADDR
  assert add_route.message_type == linux.net_constants().RTM_NEWROUTE
  request(add_address)
  let after_address = observed(intent, 2)?
  assert intent.address in after_address.addresses
  assert {local: "198.18.0.2", prefix: 24} in after_address.addresses
  assert after_address.routes.is_empty()
  match request(add_route) {
    Ok(_) => return Err(NetworkGuestError.Failed("invalid gateway unexpectedly admitted a route"))
    Err(problem) => {
      if problem.errno != 22 and problem.errno != 101 { return Err(problem) }
      let after_failure = observed(intent, 3)?
      assert after_failure.addresses == after_address.addresses
      assert after_failure.routes.is_empty()
      let events = [policy.NetworkPrecondition(before), policy.NetworkApplied(0), policy.NetworkFailed(1)]
      assert policy.network_replay(plan, events) == policy.NetworkReobserve("operation 1 failed; partial state requires observation")
      assert policy.network_replay(plan, events) == policy.network_replay(plan, events)
      let capture = json.encode({kind: "network-operation-failure", input: {intent, owned, observed: before}, completed: 1, errno: problem.errno, error: problem.message, observed: after_failure})?
      assert capture.byte_len() <= policy.network_input_limit
      print f"NETWORK_FAILURE_CAPTURE {capture}"
      match policy.network_plan(intent, owned, after_failure) {
        Ok(_) => return Err(NetworkGuestError.Failed("observed address was silently adopted without ownership"))
        Err(conflict) => {
          assert conflict.message == "desired address is foreign; ownership cannot be inferred"
          let admission = json.encode({input: {intent, owned, observed: after_failure}, error: conflict.message})?
          assert admission.byte_len() <= policy.network_input_limit
          print f"NETWORK_ADMISSION_CAPTURE {admission}"
        }
      }
    }
  }
  print "NETWORK_IPV4_FAILURE_REPLAY_OK"
}
