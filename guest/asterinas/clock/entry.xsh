#!/bin/xsh --
error NtpCaseError = Failed(message: Str)

type NtpCalibration = {correction: Float}

type NtpStatus = {state: Str, pid: Int, ready: Bool, restarts: Int}

const case_dir = p"/usr/lib/asterinas/case"
const source_rate_ppm = 100
const startup_offset_ms = 10100
const boot_clock_floor = 1000000000000
const fixture_epoch_ms = 1793000000000

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

proc main() [fs, process, env, time, io, error] {
  let mode = p"/usr/lib/asterinas/case/mode".read_text()?.trim()
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
  let supervisor = process.command_argv(/usr/bin/xsh, ["/usr/bin/xsh", "/usr/bin/xinit", "--", "supervise", "ntpd-rs"], env: {
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
  let server = unix.spawn_process_group(process.command_argv(oracle, oracle_args, stdout: /run/ntp-oracle.log, stderr: /run/ntp-oracle.log))?
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
