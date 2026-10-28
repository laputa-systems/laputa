#!/bin/xsh --
##! Runs inside a disposable DHCP qualification guest. It brings up a bound
##! `dhcpc` lease of 60 seconds against the scripted server in a private network
##! namespace, samples the monotonic, boot, wall and hardware clocks every 100
##! ms while the host pauses the machine or the guest steps its own wall clock,
##! and prints one `VMRESULT` line: the largest step of each clock between
##! consecutive samples, the requests the server saw with their guest-boot-clock
##! times, and the client's counters. The mode is the `dhcpmode=` kernel argument
##! (`pause` or `wall`).
use tests.support.dhcp_scenario as scenario
use tests.support.dhcp_script as script
use tests.support.dhcp_types as types

const LEASE_SECONDS = 60
const SAMPLE_WINDOW_MS = 110000

type Clocks = {monotonic_ms: Int, boottime_ms: Int, wall_ms: Int, rtc_ms: Int}

type Steps = {monotonic: Int, boottime: Int, wall: Int, rtc: Int, samples: Int}

type Seen = {at_ms: Int, kind: Str}

pure client_args() -> List[Str] {
  ["--lease-dir", "{dir}/lease", "--run-dir", "{dir}/run", "--resolv-dir", "{dir}/etc", "--static-file", "{dir}/etc/resolv.static", "eth0"]
}

pure rules() -> List[types.Rule] {
  [
    script.always("discover", [{...script.reply("offer"), lease: LEASE_SECONDS}]),
    script.always("request", [{...script.reply("ack"), lease: LEASE_SECONDS}]),
  ]
}

pure bound_steps(rules_file: Path) -> List[types.Step] {
  [
    scenario.server_xsh(rules_file),
    scenario.wait_for("server.requests", "", 5000),
    scenario.write("etc/resolv.static", ""),
    scenario.client("client", client_args()),
    scenario.wait_for("run/eth0.status", "\"state\":\"bound\"", 20000),
    scenario.mark("bound"),
  ]
}

pure mode_steps(mode: Str) -> List[types.Step] {
  if mode == "wall" {
    [
      scenario.sample_clocks("c1.json", 8000),
      scenario.wall_step(86400000),
      scenario.sample_clocks("c2.json", 8000),
      scenario.wall_step(-172800000),
      scenario.sample_clocks("c3.json", 8000),
      scenario.wall_step(86400000),
      scenario.sample_clocks("c4.json", 22000),
    ]
  } else {
    [scenario.mark("sampling"), scenario.sample_clocks("c1.json", SAMPLE_WINDOW_MS)]
  }
}

pure biggest(deltas: List[Int]) -> Int {
  var found = 0
  for delta in deltas {
    if delta > found or delta < 0 - found {
      found = if delta < 0 { 0 - delta } else { delta }
    }
  }
  found
}

pure steps_of(samples: List[Clocks]) -> Steps {
  Steps(
    monotonic: biggest([samples[index].monotonic_ms - samples[index - 1].monotonic_ms for index in range(1, samples.len())]),
    boottime: biggest([samples[index].boottime_ms - samples[index - 1].boottime_ms for index in range(1, samples.len())]),
    wall: biggest([samples[index].wall_ms - samples[index - 1].wall_ms for index in range(1, samples.len())]),
    rtc: biggest([samples[index].rtc_ms - samples[index - 1].rtc_ms for index in range(1, samples.len())]),
    samples: samples.len(),
  )
}

proc requests_seen(dir: Path) -> Result[List[Seen]] {
  var seen = []
  for line in fp"{dir}/server.requests".read_text()?.lines() {
    continue when line.trim() == ""
    seen += [json.decode(line)?.require(Seen)?]
  }
  seen
}

proc main() {
  var mode = "pause"
  for word in p"/proc/cmdline".read_text()?.trim().split(" ") {
    if word.starts_with("dhcpmode=") {
      mode = word.byte_slice(9)
    }
  }
  let dir = p"/run/scenario"
  dir.mkdir()
  let rules_file = fp"{dir}/rules.json"
  rules_file.write(json.encode({rules: rules()})?)
  let plan_file = fp"{dir}/scenario.json"
  plan_file.write(json.encode(types.Scenario(xsh: "/bin/xsh", core: "/core", dir: dir.display(), steps: bound_steps(rules_file).extend(mode_steps(mode))))?)
  let command = process.command_argv(
    p"/bin/xsh",
    [p"/bin/xsh", p"/core/tests/support/dhcp_driver.xsh", plan_file],
    dir,
    {XSH_MODULE_PATH: "/core", LC_ALL: "C", XSH_EXECUTION_PHRASE: ""},
    b"",
    p"/dev/ttyS0",
    fp"{dir}/driver.log",
    timeout: 1800s,
  )
  let status = linux.run_in_namespaces(command, unshare: ["mnt", "net"])?
  assert status.exited_with(0), fp"{dir}/driver.log".read_text()?
  var samples: List[Clocks] = []
  for name in ["c1", "c2", "c3", "c4"] {
    let file = fp"{dir}/{name}.json"
    if file.exists() {
      samples += json.read(file)?.require(List[Clocks])?
    }
  }
  let state = json.read(fp"{dir}/run/eth0.status")?
  let report = json.encode({mode: mode, lease_seconds: LEASE_SECONDS, steps: steps_of(samples), requests: requests_seen(dir)?, status: state})?
  print f"VMRESULT {report}"
}

main()?
