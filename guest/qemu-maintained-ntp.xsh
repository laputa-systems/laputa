#!/bin/xsh

##! Installed-guest clock discipline drill for the maintained profile. A host
##! harness selects a phase with the kernel command line token LAPUTA_NTP_DRILL;
##! without the token the script exits silently like the proof script does.
##!
##! sync     readiness precedes synchronization, all three NTS operators answer,
##!          a killed daemon is restarted and resynchronizes, then the guest reboots
##! offline  after resynchronizing across the reboot, NTS and NTP egress is cut and
##!          the wall clock must neither step nor lose the daemon

const config = p"/usr/share/ntpd-rs/ntp.toml"
const operators = ["time.cloudflare.com", "nts.netnod.se", "nts.time.nl"]
const sync_seconds = 300
const offline_seconds = 120
const largest_step_ms = 20

proc console(text: Str) {
  p"/dev/console".write(text + "\n")
}

proc phase() -> Result[Str] {
  for token in p"/proc/cmdline".read_text()?.words() {
    if token.starts_with("LAPUTA_NTP_DRILL=") {
      return token.split("=")[1]
    }
  }
  ""
}

proc service_pid(previous: Int) -> Result[Int] {
  let status = p"/run/xinit/ntpd-rs.json"
  var waited = 0
  while waited < 60 {
    if status.exists()? {
      let value = json.read(status)?
      let pid = json.get(value, ["pid"], 0).require(Int)?
      let ready = json.get(value, ["ready"], false).require(Bool)?
      if json.get(value, ["state"], "").require(Str)? == "running" and ready and pid > 0 and pid != previous {
        return pid
      }
    }
    time.sleep(500ms)
    waited += 1
  }
  for directory in [p"/run/xinit", p"/var/log", p"/var/log/ntpd-rs"] {
    if directory.exists()? {
      for entry in fs.children(directory)? { console(f"LAPUTA_NTP_DRILL_ENTRY {entry.path}") }
    }
  }
  for evidence in [p"/run/xinit/ntpd-rs.json", p"/var/log/ntpd-rs/current"] {
    if evidence.exists()? { console(evidence.read_text()?) }
  }
  fail "ntpd-rs did not become ready"
}

proc status_text() -> Result[Str] {
  run.text /usr/bin/ntp-ctl "status" "-c" f"{config}"
}

proc stratum(text: Str) -> Result[Int] {
  for line in text.lines() {
    let trimmed = line.trim()
    if trimmed.starts_with("Stratum:") {
      return trimmed.replace("Stratum:", with: "").trim().parse_int_decimal()?
    }
  }
  fail "ntp-ctl reported no stratum"
}

proc wait_synchronized() -> Result[Int] {
  var waited = 0
  while waited < sync_seconds {
    let level = stratum(status_text()?)?
    if level < 16 {
      return level
    }
    time.sleep(1s)
    waited += 1
  }
  fail f"no authenticated synchronization within {sync_seconds}s"
}

proc require_operators(text: Str) {
  for operator in operators {
    var found = false
    var lines = text.lines()
    var index = 0
    while index < lines.len() {
      if lines[index].starts_with(operator) {
        guard "[NTS]" in lines[index] else { fail f"{operator} is not an NTS source" }
        found = true
        var cursor = index + 1
        var answered = false
        while cursor < lines.len() and lines[cursor].trim() != "" {
          if lines[cursor].trim().starts_with("Missing polls:") and lines[cursor].trim().ends_with("0") {
            answered = true
          }
          cursor += 1
        }
        guard answered else { fail f"{operator} has unanswered polls" }
      }
      index += 1
    }
    guard found else { fail f"{operator} is not a configured source" }
  }
}

proc wall_minus_monotonic() -> Result[Int] {
  time.now() - time.monotonic()? / 1000000
}

proc sync_phase() {
  let first = service_pid(0)?
  let early = stratum(status_text()?)?
  guard early == 16 else { fail f"readiness already reported stratum {early}" }
  console("LAPUTA_NTP_DRILL_READY_UNSYNCHRONIZED stratum=16")
  let level = wait_synchronized()?
  let sources = status_text()?
  console(sources)
  require_operators(sources)
  console(f"LAPUTA_NTP_DRILL_SYNCHRONIZED stratum={level} operators={operators.join(",")}")
  process.kill(first, signal: "KILL")?
  let second = service_pid(first)?
  let again = wait_synchronized()?
  console(f"LAPUTA_NTP_DRILL_RESTARTED stratum={again}")
  p"/var/lib/laputa/ntp-drill".write("synchronized\n")?
  fs.fsync(p"/var/lib/laputa/ntp-drill")?
  console("LAPUTA_NTP_DRILL_OK sync")
  process.kill(1, signal: "TERM")?
}

proc offline_phase() {
  guard p"/var/lib/laputa/ntp-drill".read_text()? == "synchronized\n" else { fail "the sync phase did not complete" }
  let pid = service_pid(0)?
  let level = wait_synchronized()?
  console(f"LAPUTA_NTP_DRILL_RESYNCHRONIZED stratum={level}")
  let nft = process.run(process.command_argv(/usr/bin/nft, ["nft", "insert", "rule", "inet", "filter", "output", "meta", "l4proto", "{", "tcp,", "udp", "}", "th", "dport", "{", "123,", "4460", "}", "drop"]))?
  guard nft.shell_code()? == 0 else { fail "could not cut NTS reachability" }
  console("LAPUTA_NTP_DRILL_EGRESS_CUT")
  let baseline = wall_minus_monotonic()?
  var previous = baseline
  var largest_change = 0
  var largest_offset = 0
  var elapsed = 0
  while elapsed < offline_seconds {
    time.sleep(1s)
    let current = wall_minus_monotonic()?
    let change = if current > previous { current - previous } else { previous - current }
    let offset = if current > baseline { current - baseline } else { baseline - current }
    if change > largest_change { largest_change = change }
    if offset > largest_offset { largest_offset = offset }
    previous = current
    elapsed += 1
  }
  guard largest_change < largest_step_ms else { fail f"the clock stepped by {largest_change} ms without a source" }
  let final_pid = service_pid(0)?
  guard final_pid == pid else { fail "the daemon restarted when its sources disappeared" }
  let log = p"/var/log/ntpd-rs/current"
  if log.exists()? {
    guard ! ("jumping" in log.read_text()?) else { fail "the daemon stepped the clock" }
  }
  let text = status_text()?
  console(f"LAPUTA_NTP_DRILL_OK offline largest_sample_change_ms={largest_change} largest_offset_ms={largest_offset} stratum={stratum(text)?}")
}

proc run_drill() {
  let selected = phase()?
  return when selected == ""
  guard config.exists()? else { fail "the packaged ntpd-rs configuration is missing" }
  if selected == "sync" {
    sync_phase()?
  } else if selected == "offline" {
    offline_phase()?
  } else {
    fail f"unknown drill phase {selected}"
  }
}

proc main() -> Result[Unit, Error] {
  match run_drill() {
    Ok(_) => {}
    Err(problem) => {
      console(f"LAPUTA_NTP_DRILL_FAILED {problem.message}")
      return Err(problem)
    }
  }
}

main()?
