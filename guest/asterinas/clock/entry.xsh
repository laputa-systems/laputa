#!/bin/xsh --
use lib.nettools_fixture as fixture

error NtpCaseError = Failed(message: Str)

type NtpCalibration = {correction: Float}

type NtpStatus = {state: Str, pid: Int, ready: Bool, restarts: Int}

const case_dir = p"/usr/lib/asterinas/case"
const source_rate_ppm = 100
const startup_offset_ms = 10100
const boot_clock_floor = 1000000000000
const fixture_epoch_ms = 1793000000000
const peer_host = "192.0.2.1"
const guest_address = "192.0.2.2"
const pause_hold_ms = 5000

type PeerSample = {offset_us: Int, rtt_us: Int, real_us: Int, mono_us: Int, boot_us: Int}

proc now_ms() -> Result[Int] {
  time.monotonic()? / 1000000
}

proc wait_status(root: Path, previous: Int) -> Result[NtpStatus] {
  let deadline = now_ms()? + 20000
  while now_ms()? < deadline {
    let file = fp"{root}/ntpd-rs.json"
    if file.exists()? {
      let status: NtpStatus = json.read(file)?.require()?
      if status.state == "running" and status.ready and status.pid > 0 and status.pid != previous {
        return status
      }
    }
    time.sleep(50ms)
  }
  Err(NtpCaseError.Failed("ntpd-rs did not report supervisor readiness"))
}

proc check_identity(pid: Int) {
  let status = fp"/proc/{pid}/status".read_text()?
  assert "Uid:\t123\t123\t123\t123" in status
  assert "Gid:\t123\t123\t123\t123" in status
  for field in ["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"] {
    assert f"{field}:\t0000000002000000" in status
  }
  assert "NoNewPrivs:\t1" in status
}

proc stratum() -> Result[Int] {
  let output = run.text /usr/bin/ntp-ctl "status" "-c" "/etc/ntpd-rs/ntp.toml"
  for line in output.lines() {
    let trimmed = line.trim()
    if trimmed.starts_with("Stratum:") {
      return trimmed.replace("Stratum:", with: "").trim().parse_int_decimal()?
    }
  }
  Err(NtpCaseError.Failed("ntp-ctl did not report a stratum"))
}

pure magnitude(value: Int) -> Int {
  if value < 0 { 0 - value } else { value }
}

pure probe_field(text: Str, name: Str) -> Result[Int, Error] {
  for part in text.trim().split(" ") {
    if part.starts_with(f"{name}=") { return part.replace(f"{name}=", with: "").parse_int()? }
  }
  Err(NtpCaseError.Failed(f"ntp-probe did not report {name}"))
}

proc await_sample(probe: Path, timeout_ms: Int) -> Result[PeerSample] {
  let deadline = now_ms()? + timeout_ms
  while now_ms()? < deadline {
    let attempt = run.capture --text $probe "sample" $peer_host
    if attempt.status.ok {
      let text = attempt.stdout
      return {
        offset_us: probe_field(text, "offset_us")?,
        rtt_us: probe_field(text, "rtt_us")?,
        real_us: probe_field(text, "real_us")?,
        mono_us: probe_field(text, "mono_us")?,
        boot_us: probe_field(text, "boot_us")?,
      }
    }
    print f"NTP_PROBE_FAILED stdout={attempt.stdout.trim()} stderr={attempt.stderr.trim()}"
    time.sleep(200ms)
  }
  Err(NtpCaseError.Failed("the NTP peer did not answer"))
}

proc await_agreement(probe: Path, timeout_ms: Int, label: Str) -> Result[Int] {
  let deadline = now_ms()? + timeout_ms
  var consecutive = 0
  var worst_us = 0
  while now_ms()? < deadline {
    let sample = await_sample(probe, 5000)?
    let distance = magnitude(sample.offset_us)
    if distance > worst_us { worst_us = distance }
    let current = stratum()?
    print f"NTP_{label}_SAMPLE stratum={current} offset_us={sample.offset_us}"
    if current < 16 and distance < 100000 { consecutive += 1 } else { consecutive = 0 }
    if consecutive >= 5 { return worst_us }
    time.sleep(1s)
  }
  Err(NtpCaseError.Failed(f"the clock did not stay within 100 ms of the peer for five samples ({label})"))
}

proc peer_case(mode: Str) [fs, process, env, time, io, error] {
  let probe = fp"{case_dir}/ntp-probe"
  fixture.link_up("eth0")?
  fixture.address_add4("eth0", guest_address, 24, "192.0.2.255", "")?
  let first = await_sample(probe, 30000)?
  linux.set_system_clock(time.now() + first.offset_us / 1000)?
  let aligned = await_sample(probe, 5000)?
  assert aligned.offset_us > -20000 and aligned.offset_us < 20000, f"the clock was not aligned with the peer: {aligned.offset_us} us"
  print f"NTP_ALIGNED offset_us={aligned.offset_us} rtt_us={aligned.rtt_us}"

  p"/etc/ntpd-rs".mkdir(true)?
  p"/etc/ntpd-rs/ntp.toml".write(f"""frequency-calibration-path = "/var/lib/ntpd-rs/frequency.json"
[observability]
log-level = "info"
observation-path = "/run/ntpd-rs/observe"
observation-permissions = 0o644
[[source]]
mode = "server"
address = "{peer_host}:123"
initial-poll-interval = 1
poll-interval-limits = {{ min = 1, max = 1 }}
[synchronization]
minimum-agreeing-sources = 1
""")?
  var groups: List[Int] = []
  var completed = false
  defer {
    let daemon_log = p"/run/ntp-proof-logs/ntpd-rs/current"
    if daemon_log.exists()? { print "NTP_DAEMON_LOG" daemon_log.read_text()? }
    let cleanup = unix.shutdown_process_groups(groups, 2s, 100ms)?
    assert cleanup.remaining.is_empty(), "NTP proof retained process groups"
    if completed { print "NTP_CASE_COMPLETE" }
  }
  let run_dir = p"/run/ntp-proof"
  run_dir.mkdir(true)?
  let supervisor = process.command_argv(p"/usr/bin/xsh", ["/usr/bin/xsh", "/usr/bin/xinit", "--", "supervise", "ntpd-rs"], env: {
    XINIT_SERVICE_DIR: "/usr/lib/xinit/services",
    XINIT_RUN_DIR: run_dir.display(),
    XINIT_LOG_ROOT: "/run/ntp-proof-logs",
  })
  let scanner = unix.spawn_process_group(supervisor)?
  groups += [scanner.pid]
  let first_status = wait_status(run_dir, 0)?
  groups += [first_status.pid]
  check_identity(first_status.pid)?
  print "NTP_READY"

  let before_worst = await_agreement(probe, 120000, "BEFORE")?
  print f"NTP_SYNCED worst_offset_us={before_worst}"

  if mode == "jump" {
    linux.set_system_clock(time.now() - 5000)?
    let restarted = wait_status(run_dir, first_status.pid)?
    groups += [restarted.pid]
    check_identity(restarted.pid)?
    assert restarted.restarts > first_status.restarts, "the daemon did not restart after an external backstep"
    print "NTP_JUMP_RESTART_READY"
    let rejected = await_sample(probe, 5000)?
    assert magnitude(rejected.offset_us / 1000 - 5000) < 500, f"the rejected jump left an offset of {rejected.offset_us} us"
    let deadline = now_ms()? + 60000
    while stratum()? == 16 and now_ms()? < deadline { time.sleep(500ms) }
    assert stratum()? < 16, "the restarted daemon did not select the peer"
    time.sleep(10s)
    let steered = await_sample(probe, 5000)?
    assert steered.offset_us < rejected.offset_us, "the restarted daemon did not steer toward the peer"
    print f"NTP_JUMP_STEERING offset_us={rejected.offset_us} later_offset_us={steered.offset_us}"
    completed = true
    return
  }

  let observed = run.text $probe "pause" $peer_host f"{pause_hold_ms}"
  print "NTP_PAUSE_OBSERVED" observed.trim()
  let held = probe_field(observed, "peer_mono_ms")?
  let mono_gap = probe_field(observed, "guest_mono_ms")?
  let boot_gap = probe_field(observed, "guest_boot_ms")?
  let real_gap = probe_field(observed, "guest_real_ms")?
  assert held >= pause_hold_ms and held < pause_hold_ms + 5000, f"the peer held the guest for {held} ms"
  assert magnitude(real_gap - mono_gap) < 100 and magnitude(boot_gap - mono_gap) < 100, "the guest clocks disagree about the pause"
  let lost = held - mono_gap
  let after = await_sample(probe, 30000)?
  print f"NTP_RESUMED lost_ms={lost} offset_us={after.offset_us}"

  if lost < 1000 {
    print "NTP_PAUSE_VISIBLE"
    let after_worst = await_agreement(probe, 120000, "AFTER")?
    print f"NTP_RECOVERED worst_offset_us={after_worst}"
  } else {
    print "NTP_PAUSE_FROZEN"
    assert magnitude(after.offset_us / 1000 - lost) < 500, f"the offset {after.offset_us} us is not the {lost} ms the guest clocks lost"
    time.sleep(20s)
    let later = await_sample(probe, 5000)?
    assert stratum()? < 16, "the daemon lost its source while the clock lagged"
    assert later.offset_us < after.offset_us, "the daemon did not steer the lagging clock toward the peer"
    print f"NTP_FROZEN_STEERING offset_us={after.offset_us} later_offset_us={later.offset_us}"
  }
  let status: NtpStatus = json.read(fp"{run_dir}/ntpd-rs.json")?.require()?
  assert status.state == "running" and status.ready and status.pid == first_status.pid and status.restarts == first_status.restarts, "the pause disturbed the supervised daemon"
  print f"NTP_STATUS state={status.state} ready={status.ready} pid={status.pid} restarts={status.restarts}"
  completed = true
}

proc main() [fs, process, env, time, io, error] {
  let mode = p"/usr/lib/asterinas/case/mode".read_text()?.trim()
  if mode == "pause" or mode == "jump" {
    peer_case(mode)?
    return
  }
  let frequency_case = mode == "frequency"
  let oracle = fp"{case_dir}/ntp-oracle"
  let check = fp"{case_dir}/ntp-frequency-check"
  let saved = p"/var/lib/ntpd-rs/frequency.json"

  p"/etc/ntpd-rs".mkdir(true)?
  p"/etc/ntpd-rs/ntp.toml".write("""frequency-calibration-path = "/var/lib/ntpd-rs/frequency.json"
[observability]
log-level = "info"
observation-path = "/run/ntpd-rs/observe"
observation-permissions = 0o644
[[source]]
mode = "server"
address = "127.0.0.1:32123"
initial-poll-interval = 1
poll-interval-limits = { min = 1, max = 1 }
[synchronization]
minimum-agreeing-sources = 1
""")?
  if time.now() < boot_clock_floor {
    linux.set_system_clock(fixture_epoch_ms)?
  }
  let raw_origin = (run.text $oracle "--raw").trim().parse_int_decimal()?
  let original = time.now()
  let origin = now_ms()?
  var groups: List[Int] = []
  var completed = false
  defer {
    let daemon_log = p"/run/ntp-proof-logs/ntpd-rs/current"
    if daemon_log.exists()? { print "NTP_DAEMON_LOG" daemon_log.read_text()? }
    let cleanup = unix.shutdown_process_groups(groups, 2s, 100ms)?
    assert cleanup.remaining.is_empty(), "NTP proof retained process groups"
    linux.set_system_clock(original + now_ms()? - origin)?
    if completed { print "NTP_CASE_COMPLETE" }
  }

  if mode != "frequency" {
    let offset = if mode == "ahead" { startup_offset_ms } else { -startup_offset_ms }
    linux.set_system_clock(original + offset)?
  }
  let run_dir = p"/run/ntp-proof"
  run_dir.mkdir(true)?
  let supervisor = process.command_argv(p"/usr/bin/xsh", ["/usr/bin/xsh", "/usr/bin/xinit", "--", "supervise", "ntpd-rs"], env: {
    XINIT_SERVICE_DIR: "/usr/lib/xinit/services",
    XINIT_RUN_DIR: run_dir.display(),
    XINIT_LOG_ROOT: "/run/ntp-proof-logs",
  })
  let scanner = unix.spawn_process_group(supervisor)?
  groups += [scanner.pid]
  let first = wait_status(run_dir, 0)?
  groups += [first.pid]
  check_identity(first.pid)?
  assert stratum()? == 16, "readiness was confused with synchronization"
  print "NTP_READY_UNSYNCED"

  let ready = p"/run/ntp-oracle-ready"
  let oracle_args = if frequency_case {
    [oracle.display(), f"{original}", f"{raw_origin}", ready.display(), f"{source_rate_ppm}"]
  } else {
    [oracle.display(), f"{original}", f"{raw_origin}", ready.display()]
  }
  let server = unix.spawn_process_group(process.command_argv(oracle, oracle_args, stdout: p"/run/ntp-oracle.log", stderr: p"/run/ntp-oracle.log"))?
  groups += [server.pid]
  let server_deadline = now_ms()? + 10000
  while ! ready.exists()? and now_ms()? < server_deadline { time.sleep(50ms) }
  assert ready.exists()?, "controlled NTP source did not bind"

  let deadline = now_ms()? + 170000
  var consecutive = 0
  var learned = false
  while now_ms()? < deadline {
    let raw_now = (run.text $oracle "--raw").trim().parse_int_decimal()?
    let delta = time.now() - (original + raw_now - raw_origin)
    let current = stratum()?
    if frequency_case {
      if current < 16 and saved.exists()? {
        let valid = run.status $check "saved" $saved
        if valid.ok {
          learned = true
          break
        }
      }
    } else {
      if current < 16 and delta > -100 and delta < 100 {
        consecutive += 1
      } else {
        consecutive = 0
      }
      if consecutive >= 5 { break }
    }
    if (now_ms()? - origin) % 10000 < 1000 { print f"NTP_PROGRESS stratum={current} delta_ms={delta}" }
    time.sleep(1s)
  }
  if (frequency_case and ! learned) or (! frequency_case and consecutive < 5) {
    run /usr/bin/ntp-ctl "status" "-c" "/etc/ntpd-rs/ntp.toml"
    if p"/run/ntp-oracle-count".exists()? { print "NTP_PACKETS" p"/run/ntp-oracle-count".read_text()? }
    if p"/run/ntp-oracle.log".exists()? { print "NTP_ORACLE_LOG" p"/run/ntp-oracle.log".read_text()? }
    print "NTP_NOW_MINUS_ORIGINAL_MS" (time.now() - original)
  }
  if frequency_case {
    assert learned, "the 100 ppm source was not learned and saved"
    let calibration: NtpCalibration = json.read(saved)?.require()?
    let correction = calibration.correction
    assert correction > 0.00008 and correction < 0.00012, f"learned correction {correction} is not within 20 ppm of the source"
    print "NTP_FREQUENCY_LEARNED_AND_SAVED"
  } else {
    assert consecutive >= 5, "the clock did not stay within 100 ms of the source for five samples"
    assert "Large jump on clock" in p"/run/ntp-proof-logs/ntpd-rs/current".read_text()?, "expected a controlled clock step at startup"
    print "NTP_CLOCK_SYNCED"
  }

  let cleanup = unix.shutdown_process_groups([server.pid], 2s, 100ms)?
  assert cleanup.remaining.is_empty(), "the controlled source did not stop"
  process.kill(first.pid, signal: "KILL")?
  let replacement = wait_status(run_dir, first.pid)?
  groups += [replacement.pid]
  check_identity(replacement.pid)?
  assert replacement.restarts > first.restarts
  print "NTP_RESTART_READY"
  assert stratum()? == 16, "a restart without a source was synchronized"
  if frequency_case {
    run $check "restored" $saved
    assert "restored clock frequency calibration" in p"/run/ntp-proof-logs/ntpd-rs/current".read_text()?
    print "NTP_RESTART_RESTORED_FREQUENCY"
  }
  completed = true
}

main()?
