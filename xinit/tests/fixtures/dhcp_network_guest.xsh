#!/bin/xsh --
##! Runs inside a disposable DHCP qualification guest that has one virtio-net
##! device behind QEMU's user-mode network, whose built-in DHCP server answers
##! `dhcpc`. It watches the interface and the client's status every 20 ms and
##! records each change with the guest boot clock: carrier, interface index
##! (a removed and re-enumerated device is a new interface), and the client's
##! state. The host flaps the link over QMP; once the client is bound again the
##! guest removes its virtio-net device from the PCI bus and rescans, which
##! destroys and recreates the interface, and brings the new one up as `ifup`
##! would. It stops after the full sequence and prints one `VMRESULT` line with
##! the events.
use lib.nettools_fixture as fixture

const POLL_MS = 20
const DEADLINE_MS = 240000

type Event = {boot_ms: Int, what: Str}

type Watch = {present: Bool, ifindex: Int, carrier: Str, state: Str}

proc say(text: Str) {
  print $text
  io.flush_stdout()?
}

proc boot_ms() -> Result[Int] {
  time.boottime()? / 1000000
}

proc read_trimmed(file: Path) -> Str {
  match file.read_text() {
    Ok(text) => text.trim()
    Err(_) => ""
  }
}

proc client_state(status: Path) -> Str {
  if status.exists()? {
    if let Ok(parsed) = json.read(status) {
      let state = json.get(parsed, ["state"]) ?? { |_| return "unreadable" }
      return state.require(Str) ?? "unreadable"
    }
  }
  "none"
}

proc observe(status: Path) -> Result[Watch] {
  let present = p"/sys/class/net/eth0".exists()?
  Watch(
    present:,
    ifindex: read_trimmed(p"/sys/class/net/eth0/ifindex").parse_int() ?? 0,
    carrier: read_trimmed(p"/sys/class/net/eth0/carrier"),
    state: client_state(status),
  )
}

pure changes(before: Watch, after: Watch, at: Int) -> List[Event] {
  collect {
    yield Event(boot_ms: at, what: f"link {if after.present { "present" } else { "absent" }} ifindex={after.ifindex}") when before.present != after.present or before.ifindex != after.ifindex
    yield Event(boot_ms: at, what: f"carrier {after.carrier}") when before.carrier != after.carrier
    yield Event(boot_ms: at, what: f"state {after.state}") when before.state != after.state
  }
}

pure finished(events: List[Event]) -> Bool {
  let names = [event.what for event in events]
  var bound_after_replug = false
  var seen_absent = false
  for name in names {
    if name.starts_with("link absent") {
      seen_absent = true
    }
    if seen_absent and name == "state bound" {
      bound_after_replug = true
    }
  }
  bound_after_replug
}

proc net_device() -> Result[Path] {
  for entry in fs.children(p"/sys/bus/pci/devices")? {
    if fp"{entry.path}/vendor".read_text()?.trim() == "0x1af4" and fp"{entry.path}/device".read_text()?.trim() == "0x1000" {
      return entry.path
    }
  }
  Err(error.failure("no virtio-net PCI device"))
}

pure bound_count(events: List[Event]) -> Int {
  var count = 0
  for event in events {
    if event.what == "state bound" {
      count += 1
    }
  }
  count
}

proc main() {
  let dir = p"/run/nic"
  var unplugged = false
  var settled_at = 0
  dir.mkdir()
  let status = fp"{dir}/run/eth0.status"
  fixture.link_up("eth0")?
  let command = process.command_argv(
    p"/bin/xsh",
    [p"/bin/xsh", p"/core/dhcpc.xsh", "--lease-dir", fp"{dir}/lease".display(), "--run-dir", fp"{dir}/run".display(), "--resolv-dir", fp"{dir}/etc".display(), "--static-file", fp"{dir}/etc/resolv.static".display(), "eth0"],
    dir,
    {XSH_MODULE_PATH: "/core", LC_ALL: "C"},
    b"",
    fp"{dir}/client.log",
    fp"{dir}/client.log",
    timeout: 1800s,
  )
  fp"{dir}/etc".mkdir()
  fp"{dir}/etc/resolv.static".write("")
  let client = unix.spawn_process_group_log(command, fp"{dir}/client.log")?
  defer {
    let _ = unix.shutdown_process_groups([client.pid], 2s, 100ms)?
  }
  var events: List[Event] = [Event(boot_ms: boot_ms()?, what: "started")]
  var before = Watch(present: false, ifindex: 0, carrier: "", state: "none")
  let deadline = boot_ms()? + DEADLINE_MS
  say("VMMARK watching")?
  while boot_ms()? < deadline and ! finished(events) {
    let now = boot_ms()?
    let after = observe(status)?
    let seen = changes(before, after, now)
    for event in seen {
      say(f"VMMARK {event.what}")?
    }
    events += seen
    if after.present and ! before.present {
      fixture.link_up("eth0")?
    }
    if bound_count(events) >= 2 and settled_at == 0 {
      settled_at = now
    }
    var current = after
    if settled_at != 0 and ! unplugged and now - settled_at >= 2000 {
      let device = net_device()?
      unplugged = true
      say("VMMARK unplug")?
      fp"{device}/remove".write("1")
      while p"/sys/class/net/eth0".exists()? {
        time.sleep(5ms)
      }
      let absent = Event(boot_ms: boot_ms()?, what: "link absent ifindex=0")
      events += [absent]
      say(f"VMMARK {absent.what}")?
      current = Watch(present: false, ifindex: 0, carrier: "", state: after.state)
      time.sleep(1500ms)
      p"/sys/bus/pci/rescan".write("1")
      say("VMMARK rescan")?
    }
    before = current
    time.sleep(POLL_MS * 1ms)
  }
  let report = json.encode({events: events, finished: finished(events)})?
  say(f"VMRESULT {report}")?
}

main()?
