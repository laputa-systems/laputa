#!/bin/xsh --
use lib.dhcp_apply as apply
use lib.dhcp_net as network
use lib.dhcp_wire as wire
use lib.gnu as gnu
use lib.net_state as state
use lib.nettools_fixture as fixture

const WORK = p"/run/dhcp-case"
const POLL_MS = 20
const FOREIGN = "198.51.100.5"
const FOREIGN_RESOLVER = "10.0.0.53"
const STATIC_ROUTE_PROTOCOL = 4
const ETH_P_ALL = 3
const ETH_P_IP = 2048
const DHCP_SERVER_PORT = 67
const IFLA_STATS = 7
const IFLA_STATS64 = 23
const IFLA_CARRIER = 33
const IFLA_CARRIER_CHANGES = 35
const IFLA_CARRIER_UP_COUNT = 47
const IFLA_CARRIER_DOWN_COUNT = 48
const RTN_UNICAST = 1
const RTN_LOCAL = 2
const RTN_BLACKHOLE = 6
const RTN_UNREACHABLE = 7
const RTN_PROHIBIT = 8
const RTN_THROW = 9
const TABLE_DEFAULT = 253
const SCOPE_HOST = 254
const SCOPE_NOWHERE = 255
const KMSG_RECORD_LIMIT = 8192

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

pure attribute_number(attributes: List[LinuxNetlinkAttribute], kind: Int) -> Str {
  for attribute in attributes {
    guard attribute.kind.bit_and(16383) == kind else { continue }
    return f"{bytes.unpack_le(attribute.data, if attribute.data.len() < 4 { attribute.data.len() } else { 4 }) ?? -1}"
  }
  "-"
}

pure counter(data: Bytes, width: Int, index: Int) -> Int {
  bytes.unpack_le(data, width, index * width) ?? -1
}

pure frames_counted(attributes: List[LinuxNetlinkAttribute]) -> Bool {
  for attribute in attributes {
    guard attribute.kind.bit_and(16383) == IFLA_STATS64 else { continue }
    let fields = [counter(attribute.data, 8, index) for index in range(4)]
    return fields[0] > 0 and fields[1] > 0 and fields[2] > fields[0] and fields[3] > fields[1]
  }
  false
}

pure counter_line(attributes: List[LinuxNetlinkAttribute], kind: Int, width: Int) -> Str {
  for attribute in attributes {
    guard attribute.kind.bit_and(16383) == kind else { continue }
    let data = attribute.data
    let fields = [counter(data, width, index) for index in range(21)]
    return f"size={data.len()} tx_errors={fields[5]} collisions={fields[9]} tx_aborted={fields[16]} tx_carrier={fields[17]} tx_fifo={fields[18]} tx_heartbeat={fields[19]} tx_window={fields[20]}"
  }
  "absent"
}

proc link_lines(label: Str) [fs, process, env, net, error] {
  let dump = linux.network_dump()?
  for link in dump.links {
    guard let name = link.name else { continue }
    guard name in ["lo", "eth0"] else { continue }
    eprint --flush f"NET_DHCP_{label}_CARRIER {name} carrier={attribute_number(link.attributes, IFLA_CARRIER)} changes={attribute_number(link.attributes, IFLA_CARRIER_CHANGES)} up={attribute_number(link.attributes, IFLA_CARRIER_UP_COUNT)} down={attribute_number(link.attributes, IFLA_CARRIER_DOWN_COUNT)}"
    eprint --flush f"NET_DHCP_{label}_STATS64 {name} {counter_line(link.attributes, IFLA_STATS64, 8)}"
    eprint --flush f"NET_DHCP_{label}_STATS {name} {counter_line(link.attributes, IFLA_STATS, 4)}"
    if name == "eth0" { eprint --flush f"NET_DHCP_{label}_FRAMES {name} counted={frames_counted(link.attributes)}" }
  }
  let listing = fp"{WORK}/ifconfig.out"
  let status = process.run(process.command_argv(p"/usr/bin/xsh", [p"/usr/bin/xsh", p"/usr/lib/xsh/core/ifconfig", "eth0"], WORK, {XSH_MODULE_PATH: "/usr/lib/xsh/core", LC_ALL: "C"}, b"", listing, listing))?
  guard status.ok else { fail f"ifconfig eth0 failed: {listing.read_text()?}" }
  for line in listing.read_text()?.lines() {
    if line.trim().starts_with("TX errors") { eprint --flush f"NET_DHCP_{label}_IFCONFIG {line.trim()}" }
  }
}

pure foreign_route(destination: Str, table: Int, scope: Int, route_type: Int, hop: state.Hop) -> state.Route {
  {family: .Inet, table: table, destination: destination, prefix: 24, source: null, source_prefix: 0, preferred_source: null, tos: 0, priority: 0, protocol: STATIC_ROUTE_PROTOCOL, scope: scope, route_type: route_type, flags: 0, hops: [hop], other_attributes: []}
}

proc route_change(label: Str, change: state.Change) [process, net, error] {
  match state.apply(change) {
    Ok(_) => eprint --flush f"NET_DHCP_reject_{label} ok"
    Err(failure) => eprint --flush f"NET_DHCP_reject_{label} {failure.message}"
  }
}

proc connect_through(label: Str, address: Str) [process, net, error] {
  let c = linux.net_constants()
  let fd = linux.socket(c.AF_INET, c.SOCK_DGRAM)?
  defer unix.close_fd(fd)
  match linux.connect(fd, {family: "inet", address: address, port: 9}) {
    Ok(_) => eprint --flush f"NET_DHCP_reject_CONNECT {label} {address} source={linux.getsockname(fd)?.address}"
    Err(failure) => eprint --flush f"NET_DHCP_reject_CONNECT {label} {address} errno={gnu.errno(failure)}"
  }
}

proc reject_route_lines(label: Str) [process, env, net, error] {
  let dump = linux.network_dump()?
  for route in dump.routes {
    guard route.family == "inet" and route.table != 255 and (route.destination ?? "").starts_with("203.0.") else { continue }
    eprint --flush f"NET_DHCP_{label}_REJECT_ROUTE {route.destination ?? "default"}/{route.destination_prefix_length} oif={route.output_ifindex ?? 0} table={route.table} proto={route.protocol} scope={route.scope} type={route.route_type}"
  }
}

proc await_default_route(label: Str, timeout_ms: Int) [process, env, time, net, error] {
  let deadline = elapsed_ms()? + timeout_ms
  while elapsed_ms()? < deadline {
    let dump = linux.network_dump()?
    if dump.routes |> any .family == "inet" and .table == network.TABLE_MAIN and .destination == null { return }
    time.sleep(POLL_MS * 1ms)
  }
  eprint --flush f"NET_DHCP_{label}_TIMEOUT waiting for the default route"
}

proc reject_routes() [fs, process, env, time, net, error] {
  let none: state.Hop = {ifindex: null, gateway: null}
  let eth0 = fixture.index_of("eth0")
  let rejecting = [RTN_BLACKHOLE, RTN_UNREACHABLE, RTN_PROHIBIT, RTN_THROW]
  for route_type in rejecting + [RTN_LOCAL, 3, 4, 5] {
    route_change(f"ADD type={route_type}", state.AddRoute(foreign_route(f"203.0.{route_type + 100}.0", network.TABLE_MAIN, 0, route_type, none)))?
  }
  reject_route_lines("added")?
  fixture.link_down("eth0")?
  await_state("down", "no_link", 15000)?
  reject_route_lines("down")?
  fixture.link_up("eth0")?
  await_state("up", "bound", 40000)?
  await_default_route("rebound", 10000)?
  let _ = snapshot("rebound")?
  reject_route_lines("rebound")?
  for route_type in rejecting { connect_through("rejected", f"203.0.{route_type + 100}.1")? }
  route_change("THROW_FALLBACK", state.AddRoute(foreign_route("203.0.109.0", TABLE_DEFAULT, 0, RTN_UNICAST, {ifindex: eth0, gateway: "192.0.2.1"})))?
  connect_through("thrown", "203.0.109.1")?
  route_change("WITH_GATEWAY", state.AddRoute(foreign_route("203.0.120.0", network.TABLE_MAIN, 0, RTN_BLACKHOLE, {ifindex: null, gateway: "192.0.2.1"})))?
  route_change("WITH_DEVICE", state.AddRoute(foreign_route("203.0.121.0", network.TABLE_MAIN, 0, RTN_UNREACHABLE, {ifindex: eth0, gateway: null})))?
  route_change("DUPLICATE", state.AddRoute(foreign_route("203.0.106.0", network.TABLE_MAIN, 0, RTN_BLACKHOLE, none)))?
  route_change("NOWHERE_SCOPE", state.AddRoute(foreign_route("203.0.122.0", network.TABLE_MAIN, SCOPE_NOWHERE, RTN_PROHIBIT, none)))?
  route_change("HOST_SCOPE", state.AddRoute(foreign_route("203.0.123.0", network.TABLE_MAIN, SCOPE_HOST, RTN_BLACKHOLE, none)))?
  route_change("UNICAST_NOWHERE_SCOPE", state.AddRoute(foreign_route("203.0.124.0", network.TABLE_MAIN, SCOPE_NOWHERE, RTN_UNICAST, {ifindex: eth0, gateway: null})))?
  for route_type in [0, 10, 12] {
    route_change(f"INVALID type={route_type}", state.AddRoute(foreign_route("203.0.125.0", network.TABLE_MAIN, 0, route_type, none)))?
  }
  for route_type in rejecting {
    route_change(f"DELETE type={route_type}", state.RemoveRoute(foreign_route(f"203.0.{route_type + 100}.0", network.TABLE_MAIN, 0, route_type, none)))?
  }
  route_change("DELETE_AGAIN", state.RemoveRoute(foreign_route("203.0.106.0", network.TABLE_MAIN, 0, RTN_BLACKHOLE, none)))?
  connect_through("released", "203.0.106.1")?
  reject_route_lines("deleted")?
}

pure syslog_record(line: Str) -> Str {
  var fields: List[Str] = []
  for field in rx" header_time=\x22[^\x22]*\x22".replace(line, with: "").split(" ") {
    let name = field.split("=")[0]
    guard !(name in ["seq", "boot", "boottime_ns", "kseq", "ktime_us", "tag_pid"]) else { continue }
    if name == "pid" and field != "pid=-" { fields += ["pid=N"] } else { fields += [field] }
  }
  fields.join(" ")
}

proc kmsg_errno(label: Str, attempt: Result[Bytes, Error]) {
  match attempt {
    Ok(record) => eprint --flush f"NET_DHCP_kmsg_{label} {kmsg_record(record)}"
    Err(failure) => eprint --flush f"NET_DHCP_kmsg_{label} errno={gnu.errno(failure)}"
  }
}

pure kmsg_record(record: Bytes) -> Str {
  let text = record.utf8() ?? "undecodable"
  let fields = text.split(";")
  let header = fields[0].split(",")
  return f"malformed {text.trim()}" when header.len() < 4
  f"priority={header[0]} flag={header[3]} text={fields[1..].join(";").trim()}"
}

proc kmsg_write(label: Str, text: Str) [fs, error] {
  match p"/dev/kmsg".write(text) {
    Ok(_) => eprint --flush f"NET_DHCP_kmsg_{label} written"
    Err(failure) => eprint --flush f"NET_DHCP_kmsg_{label} errno={gnu.errno(failure)}"
  }
}

proc kmsg_device() [fs, process, net, error] {
  let fd = unix.open_fd(p"/dev/kmsg", nonblock: true)?
  defer unix.close_fd(fd)
  let _ = unix.seek_fd(fd, 0, whence: "end")?
  kmsg_errno("empty", unix.read_fd(fd, KMSG_RECORD_LIMIT))
  kmsg_write("plain", "laputa-kmsg plain record\n")
  kmsg_write("daemon", "<29>laputa-kmsg daemon notice")
  kmsg_write("kernel_facility", "<6>laputa-kmsg facility zero")
  kmsg_write("escaped", "<14>laputa-kmsg tab\there\\back")
  kmsg_write("unterminated_prefix", "<6laputa-kmsg open prefix")
  for length in [1000, 1024, 1025] { kmsg_write(f"length {length}", ["a" for _ in range(length)].join("")) }
  kmsg_errno("short_buffer", unix.read_fd(fd, 16))
  for label in ["plain", "daemon", "kernel_facility", "escaped", "unterminated_prefix"] {
    kmsg_errno(f"read {label}", unix.read_fd(fd, KMSG_RECORD_LIMIT))
  }
  for label in ["current", "offset"] {
    let attempt = if label == "current" { unix.seek_fd(fd, 0, whence: "current") } else { unix.seek_fd(fd, 5, whence: "start") }
    match attempt {
      Ok(position) => eprint --flush f"NET_DHCP_kmsg_seek {label} position={position}"
      Err(failure) => eprint --flush f"NET_DHCP_kmsg_seek {label} errno={gnu.errno(failure)}"
    }
  }
  let behind = unix.open_fd(p"/dev/kmsg", nonblock: true)?
  defer unix.close_fd(behind)
  let _ = unix.seek_fd(behind, 0, whence: "end")?
  let filler = ["f" for _ in range(960)].join("")
  for index in range(600) { p"/dev/kmsg".write(f"laputa-kmsg fill {index} {filler}")? }
  kmsg_errno("overrun", unix.read_fd(behind, KMSG_RECORD_LIMIT))
  match unix.read_fd(behind, KMSG_RECORD_LIMIT) {
    Ok(_) => eprint --flush "NET_DHCP_kmsg_after_overrun record"
    Err(failure) => eprint --flush f"NET_DHCP_kmsg_after_overrun errno={gnu.errno(failure)}"
  }
}

proc syslog_consumer() [fs, process, env, time, net, error] {
  let log = fp"{WORK}/syslog.out"
  let errors = fp"{WORK}/syslog.err"
  let command = process.command_argv(p"/usr/bin/xsh", ["/usr/bin/xsh", "/usr/lib/xsh/core/syslogd", "--state", WORK.display(), "--socket", "/dev/log", "--kmsg", "/dev/kmsg"], WORK, {XSH_MODULE_PATH: "/usr/lib/xsh/core", LC_ALL: "C"}, b"", log, errors, timeout: 600s)
  let receiver = unix.spawn_process_group_log(command, log)?
  let deadline = elapsed_ms()? + 15000
  while elapsed_ms()? < deadline and !p"/dev/log".exists()? { time.sleep(50ms) }
  eprint --flush f"NET_DHCP_syslog_SOCKET published={p"/dev/log".exists()?}"
  for mode in ["basic", "multiline", "forge"] {
    let status = process.run(process.command_argv(p"/usr/lib/asterinas/case/syslog-client", [p"/usr/lib/asterinas/case/syslog-client", mode]))?
    eprint --flush f"NET_DHCP_syslog_CLIENT {mode} ok={status.ok}"
  }
  let logged = elapsed_ms()? + 10000
  while elapsed_ms()? < logged and !(log.exists()? and "forged" in log.read_text()?) { time.sleep(POLL_MS * 1ms) }
  p"/dev/kmsg".write("<14>laputa-syslog: a kernel ring record\n")?
  time.sleep(1s)
  let _ = unix.shutdown_process_groups([receiver.pid], 3s, 100ms)?
  for line in log.read_text()?.lines() {
    guard !("source=kmsg" in line) or "laputa-syslog" in line else { continue }
    guard !line.starts_with("event=stop") else {
      eprint --flush f"NET_DHCP_syslog_STOP {[field for field in line.split(" ") if field.starts_with("dropped_") or field.starts_with("senders=")].join(" ")}"
      continue
    }
    eprint --flush f"NET_DHCP_syslog_LINE {syslog_record(line)}"
  }
  if errors.exists()? {
    for line in errors.read_text()?.lines() { eprint --flush f"NET_DHCP_syslog_ERR {line}" }
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
      link_lines("bound")?
      for cycle in [1, 2, 3] {
        fixture.link_down("eth0")?
        await_state(f"down{cycle}", "no_link", 15000)?
        let _ = snapshot(f"down{cycle}")?
        link_lines(f"down{cycle}")?
        fixture.link_up("eth0")?
        await_state(f"up{cycle}", "bound", 40000)?
        messages(f"up{cycle}", capture)?
        let _ = snapshot(f"up{cycle}")?
        link_lines(f"up{cycle}")?
      }
    }
    "reject-routes" => {
      await_state("bound", "bound", 30000)?
      reject_routes()?
    }
    "syslog" => {
      await_state("bound", "bound", 30000)?
      kmsg_device()?
      syslog_consumer()?
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
