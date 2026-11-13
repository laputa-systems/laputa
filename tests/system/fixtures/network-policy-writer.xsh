##! A separately owned writer for the disposable virtual-network witness.
use lib.net_state

proc write_change(scope: Str, barrier: Path, ifindex: Int, controller: Int, namespace: Path) {
  assert scope == "disposable-namespace", "writer requires the disposable namespace fixture"
  let current = process.current_pid()?
  assert current != controller and process.parent_pid()? == controller
  assert p"/proc/self/ns/net".readlink()? == namespace
  let state = net_state.observe()?
  let selected = [link for link in state.links if link.ifindex == ifindex and link.name == "lap-net0" and link.kind == "veth"]
  assert selected.len() == 1, "writer did not inherit the selected virtual interface"
  fp"{barrier}/ready".write_atomic(f"{current}")
  wait until fp"{barrier}/mutate".exists()? within 5s every 10ms
  let address: net_state.Address = {ifindex, family: .Inet, local: "198.18.3.3", prefix: 24, peer: null, broadcast: null, scope: 0, flags: 0}
  net_state.apply(net_state.AddAddress(address))?
  # Linux reports a configured static address with IFA_F_PERMANENT.
  let installed = {...address, flags: 128}
  assert installed in net_state.observe()?.addresses
  fp"{barrier}/changed".write_atomic(f"{current}")
  wait until fp"{barrier}/release".exists()? within 5s every 10ms
}

proc main(...argv: List[Str]) {
  assert argv.len() == 5
  write_change(argv[0], fp"{argv[1]}", argv[2].parse_int()?, argv[3].parse_int()?, fp"{argv[4]}")
}
