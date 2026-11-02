#!/bin/xsh --
use lib.dhcp_apply as apply
use lib.dhcp_net as network
use lib.dhcp_wire as wire
use lib.nettools_fixture as fixture

const WORK = p"/run/dhcp-case"
const POLL_MS = 20
const FOREIGN = "198.51.100.5"
const FOREIGN_RESOLVER = "10.0.0.53"
const STATIC_ROUTE_PROTOCOL = 4
const ETH_P_ALL = 3
const ETH_P_IP = 2048
const DHCP_SERVER_PORT = 67

type ClientStatus = {state: Str}

type Client = {pid: Int}

pure acquiring(state: Str) -> Bool {
  state in ["init", "selecting", "requesting", "probing"]
}

pure significant(state: Str) -> Str {
  if acquiring(state) { "acquiring" } else { state }
}

proc client_state() [fs, error] -> Str {
  let status = fp"{WORK}/run/eth0.status"
  guard status.exists()? else { return "none" }
  match json.read(status) {
    Ok(parsed) => parsed.require(ClientStatus)?.state
    Err(_) => "unreadable"
  }
}

proc start_client() [fs, process, error] -> Result[Client] {
  let log = fp"{WORK}/client.log"
  let command = process.command_argv(
    p"/usr/bin/xsh",
    [p"/usr/bin/xsh", p"/usr/lib/xsh/core/dhcpc", "--lease-dir", fp"{WORK}/lease".display(), "--run-dir", fp"{WORK}/run".display(), "--resolv-dir", fp"{WORK}/etc".display(), "--static-file", fp"{WORK}/etc/resolv.static".display(), "eth0"],
    WORK,
    {XSH_MODULE_PATH: "/usr/lib/xsh/core", LC_ALL: "C"},
    b"",
    log,
    log,
    timeout: 1800s,
  )
  let client = unix.spawn_process_group_log(command, log)?
  Ok(Client(pid: client.pid))
}

proc stop_client(client: Client) [process, time, error] {
  let _ = unix.shutdown_process_groups([client.pid], 3s, 100ms)?
}

proc crash_client(client: Client) [fs, process, time, error] {
  process.kill_group(client.pid, "KILL")?
  time.sleep(500ms)
  let status = fp"{WORK}/run/eth0.status"
  if status.exists()? { status.remove()? }
}

proc elapsed_ms() [time, error] -> Result[Int] {
  time.monotonic()? / 1000000
}

proc show_client_log() [fs, error] {
  let log = fp"{WORK}/client.log"
  if log.exists()? {
    for line in log.read_text()?.lines() { eprint --flush f"NET_DHCP_CLIENT_LOG {line}" }
  }
}

proc await_state(label: Str, wanted: Str, timeout_ms: Int) [fs, time, error] {
  let deadline = elapsed_ms()? + timeout_ms
  while elapsed_ms()? < deadline {
    if significant(client_state()) == wanted { return }
    time.sleep(POLL_MS * 1ms)
  }
  eprint --flush f"NET_DHCP_{label}_TIMEOUT waiting for {wanted}, last {client_state()}"
  show_client_log()?
}

proc watch_states(label: Str, duration_ms: Int) [fs, time, error] {
  var sequence: List[Str] = []
  let deadline = elapsed_ms()? + duration_ms
  while elapsed_ms()? < deadline {
    let state = significant(client_state())
    if sequence.is_empty() or sequence[sequence.len() - 1] != state { sequence += [state] }
    time.sleep(POLL_MS * 1ms)
  }
  eprint --flush f"NET_DHCP_{label}_STATES {sequence.join(">")}"
}

pure ip_text(data: Bytes, offset: Int) -> Str {
  f"{data.byte_at(offset) ?? 0}.{data.byte_at(offset + 1) ?? 0}.{data.byte_at(offset + 2) ?? 0}.{data.byte_at(offset + 3) ?? 0}"
}

pure message_name(kind: Int) -> Str {
  match kind {
    1 => "discover"
    3 => "request"
    4 => "decline"
    7 => "release"
    8 => "inform"
    else => f"type{kind}"
  }
}

pure option_value(frame: Bytes, start: Int, wanted: Int) -> Int {
  var offset = start
  while offset + 1 < frame.len() {
    let kind = frame.byte_at(offset) ?? 255
    return 0 when kind == 255
    if kind == 0 {
      offset += 1
    } else {
      let length = frame.byte_at(offset + 1) ?? 0
      return frame.byte_at(offset + 2) ?? 0 when kind == wanted
      offset += 2 + length
    }
  }
  0
}

pure client_message(frame: Bytes) -> Str? {
  return null when frame.len() < 14 + 20 + 8 + 240
  return null when (bytes.unpack_be(frame, 2, 12) ?? 0) != ETH_P_IP
  return null when frame.byte_at(23) != 17
  let header = (frame.byte_at(14) ?? 0).bit_and(15) * 4
  let udp = 14 + header
  return null when (bytes.unpack_be(frame, 2, udp + 2) ?? 0) != DHCP_SERVER_PORT
  let bootp = udp + 8
  return null when frame.byte_at(bootp) != 1
  let kind = option_value(frame, bootp + 240, 53)
  let where = if frame[0..6] == b"\xff\xff\xff\xff\xff\xff" { "broadcast" } else { "unicast" }
  f"{message_name(kind)} {where} ciaddr={ip_text(frame, bootp + 12)} ip={ip_text(frame, 26)}>{ip_text(frame, 30)} len={frame.len()}"
}

pure packet_address(ifindex: Int, protocol: Int) -> Result[Bytes, Error] {
  bytes.concat([bytes.pack_le(17, 2)?, bytes.pack_be(protocol, 2)?, bytes.pack_le(ifindex, 4)?, bytes.zero(12)?])
}

proc open_capture(ifindex: Int) [process, net, error] -> Result[Int] {
  let c = linux.net_constants()
  let socket = linux.socket(c.AF_PACKET, c.SOCK_RAW.bit_or(c.SOCK_NONBLOCK), bytes.unpack_le(bytes.pack_be(ETH_P_ALL, 2)?, 2)?)?
  linux.bind(socket, packet_address(ifindex, ETH_P_ALL)?)?
  Ok(socket)
}

proc messages(label: Str, capture: Int) [fs, process, net, time, error] {
  time.sleep(300ms)
  var previous = ""
  while unix.poll_fd(capture, ["readable"], 0)? != [] {
    match unix.read_fd(capture, 2048) {
      Ok(frame) => {
        if let text = client_message(frame) {
          if text != previous { eprint --flush f"NET_DHCP_{label}_MSG {text}" }
          previous = text
        }
      }
      Err(_) => {}
    }
  }
}

proc start_tcp_client() [fs, process, error] -> Result[Client] {
  let result = fp"{WORK}/tcp-result"
  let program = p"/usr/lib/asterinas/case/tcp-client"
  let command = process.command_argv(program, [program, "disrupted"], WORK, {LC_ALL: "C"}, b"", result, result, timeout: 300s)
  let client = unix.spawn_process_group_log(command, result)?
  Ok(Client(pid: client.pid))
}

proc await_file(file: Path, timeout_ms: Int) [fs, time, error] -> Result[Bool] {
  let deadline = elapsed_ms()? + timeout_ms
  while elapsed_ms()? < deadline {
    if file.exists()? { return Ok(true) }
    time.sleep(POLL_MS * 1ms)
  }
  Ok(false)
}

pure static_route(destination: Str, prefix: Int, gateway: Str, metric: Int) -> Result[network.Route, Error] {
  guard let destination_address = wire.ip_parse(destination) else { fail f"bad route destination {destination}" }
  guard let gateway_address = wire.ip_parse(gateway) else { fail f"bad route gateway {gateway}" }
  Ok({destination: destination_address, prefix: prefix, gateway: gateway_address, table: network.TABLE_MAIN, tos: 0, priority: metric, protocol: STATIC_ROUTE_PROTOCOL})
}

proc add_foreign_routes() [process, net, error] {
  let ifindex = fixture.index_of("eth0")
  let routes = [static_route("203.0.113.0", 24, "192.0.2.1", 50)?, static_route("0.0.0.0", 0, "192.0.2.254", 700)?]
  for route in routes {
    apply.mutate("eth0", ifindex, network.AddRoute(route))?
  }
}

proc state_lines() [fs, process, env, time, net, error] -> Result[List[Str]] {
  let dump = linux.network_dump()?
  var lines: List[Str] = []
  var eth0 = 0
  var names: Map[Int, Str] = {}
  for link in dump.links {
    names[link.ifindex] = link.name ?? "-"
    if link.name == "eth0" { eth0 = link.ifindex }
  }
  lines += [f"STATE {client_state()}"]
  for address in dump.addresses {
    guard address.family == "inet" and (address.ifindex == eth0 or address.local == FOREIGN) else { continue }
    lines += [f"ADDR {names.get(address.ifindex) ?? "-"} {address.local ?? "-"}/{address.prefix_length} brd={address.broadcast ?? "-"} scope={address.scope} label={address.label ?? "-"}"]
  }
  for route in dump.routes {
    guard route.family == "inet" and route.output_ifindex == eth0 else { continue }
    lines += [f"ROUTE {route.destination ?? "default"}/{route.destination_prefix_length} via={route.gateway ?? "-"} table={route.table} proto={route.protocol} scope={route.scope} type={route.route_type} prio={route.priority ?? 0}"]
  }
  let resolv = fp"{WORK}/etc/resolv.conf"
  if resolv.exists()? {
    for line in resolv.read_text()?.lines() {
      guard line.starts_with("nameserver") else { continue }
      lines += [f"RESOLV {line}"]
    }
  }
  Ok(lines)
}

proc snapshot(label: Str) [fs, process, env, time, net, error] -> Result[List[Str]] {
  let lines = state_lines()?
  for line in lines { eprint --flush f"NET_DHCP_{label}_{line}" }
  Ok(lines)
}

proc require_state(label: Str, lines: List[Str], present: List[Str], absent: List[Str]) [error] {
  for wanted in present {
    guard wanted in lines else { fail f"NET_DHCP_{label}_ASSERT missing: {wanted}" }
  }
  for unwanted in absent {
    guard !(unwanted in lines) else { fail f"NET_DHCP_{label}_ASSERT unexpected: {unwanted}" }
  }
}

proc main() [fs, process, env, time, net, io, error] {
  let mode = p"/usr/lib/asterinas/case/mode".read_text()?.trim()
  eprint --flush f"NET_BEGIN {mode}"
  fp"{WORK}/etc".mkdir(parents: true)?
  fp"{WORK}/etc/resolv.static".write(f"nameserver {FOREIGN_RESOLVER}\n")?
  fixture.link_up("eth0")?
  fixture.address_add4("lo", FOREIGN, 32, FOREIGN, "")?
  let capture = open_capture(fixture.index_of("eth0"))?
  var client = start_client()?
  match mode {
    "lease-acquire" => {
      await_state("bound", "bound", 30000)?
      messages("bound", capture)?
      let _ = snapshot("bound")?
    }
    "lifecycle" => {
      await_state("bound", "bound", 30000)?
      let _ = snapshot("bound")?
      watch_states("lease", 24000)?
      messages("lease", capture)?
      let _ = snapshot("expired")?
    }
    "renewal" => {
      await_state("bound", "bound", 30000)?
      time.sleep(24s)
      messages("renewed", capture)?
      let _ = snapshot("renewed")?
    }
    "reconfigure" => {
      await_state("bound", "bound", 30000)?
      add_foreign_routes()?
      let first = snapshot("bound")?
      require_state(
        "bound",
        first,
        [
          "ADDR lo 198.51.100.5/32 brd=198.51.100.5 scope=0 label=lo",
          "ROUTE default/0 via=192.0.2.1 table=254 proto=16 scope=0 type=1 prio=100",
          "ROUTE default/0 via=192.0.2.254 table=254 proto=4 scope=0 type=1 prio=700",
          "ROUTE 203.0.113.0/24 via=192.0.2.1 table=254 proto=4 scope=0 type=1 prio=50",
          "RESOLV nameserver 10.0.0.53",
          "RESOLV nameserver 192.0.2.1",
        ],
        [],
      )?
      time.sleep(14s)
      messages("renewed", capture)?
      let renewed = snapshot("renewed")?
      require_state(
        "renewed",
        renewed,
        [
          "STATE bound",
          "ADDR lo 198.51.100.5/32 brd=198.51.100.5 scope=0 label=lo",
          "ADDR eth0 192.0.2.100/24 brd=192.0.2.255 scope=0 label=eth0",
          "ROUTE 198.18.0.0/24 via=192.0.2.1 table=254 proto=16 scope=0 type=1 prio=100",
          "ROUTE 198.19.0.0/24 via=- table=254 proto=16 scope=253 type=1 prio=100",
          "ROUTE default/0 via=192.0.2.254 table=254 proto=4 scope=0 type=1 prio=700",
          "ROUTE 203.0.113.0/24 via=192.0.2.1 table=254 proto=4 scope=0 type=1 prio=50",
          "RESOLV nameserver 10.0.0.53",
          "RESOLV nameserver 192.0.2.53",
          "RESOLV nameserver 192.0.2.54",
        ],
        [
          "ROUTE default/0 via=192.0.2.1 table=254 proto=16 scope=0 type=1 prio=100",
          "RESOLV nameserver 192.0.2.1",
        ],
      )?
    }
    "nak" => {
      await_state("bound", "bound", 30000)?
      time.sleep(24s)
      messages("nak", capture)?
      let _ = snapshot("after_nak")?
    }
    "restart" => {
      await_state("bound", "bound", 30000)?
      let _ = snapshot("bound")?
      crash_client(client)?
      let _ = snapshot("crashed")?
      client = start_client()?
      await_state("restarted", "bound", 30000)?
      messages("restarted", capture)?
      let _ = snapshot("restarted")?
    }
    "carrier" => {
      await_state("bound", "bound", 30000)?
      let _ = snapshot("bound")?
      for cycle in [1, 2, 3] {
        fixture.link_down("eth0")?
        await_state(f"down{cycle}", "no_link", 15000)?
        let _ = snapshot(f"down{cycle}")?
        fixture.link_up("eth0")?
        await_state(f"up{cycle}", "bound", 40000)?
        messages(f"up{cycle}", capture)?
        let _ = snapshot(f"up{cycle}")?
      }
    }
    "tcp" => {
      await_state("bound", "bound", 30000)?
      let before = run.text /usr/lib/asterinas/case/tcp-client "transfer"
      eprint --flush f"NET_DHCP_tcp_before {before.trim()}"
      let _ = start_tcp_client()?
      if !await_file(fp"{WORK}/halfway", 60000)? { eprint --flush "NET_DHCP_tcp_TIMEOUT waiting for the halfway mark" }
      fixture.link_down("eth0")?
      await_state("down", "no_link", 15000)?
      fixture.link_up("eth0")?
      await_state("up", "bound", 40000)?
      time.sleep(500ms)
      let _ = snapshot("rebound")?
      fp"{WORK}/resume".write("x\n")?
      if !await_file(fp"{WORK}/tcp-done", 150000)? { eprint --flush "NET_DHCP_tcp_TIMEOUT waiting for the transfer" }
      for line in fp"{WORK}/tcp-result".read_text()?.lines() {
        if line.starts_with("DHCP_DETAIL") { eprint --flush $line } else { eprint --flush f"NET_DHCP_tcp_disrupted {line}" }
      }
      let after = run.text /usr/lib/asterinas/case/tcp-client "transfer"
      eprint --flush f"NET_DHCP_tcp_after {after.trim()}"
    }
    other => fail f"unknown dhcp mode {other}"
  }
  stop_client(client)?
  show_client_log()?
  eprint --flush "NET_DONE"
}
main()
