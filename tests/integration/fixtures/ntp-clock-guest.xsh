use pm.generation

error NtpGuestError = Failed(message: Str)

type NtpGuestStatus = {state: Str, pid: Int, ready: Bool, restarts: Int}

proc now_ms() -> Result[Int] {
  time.monotonic()? / 1000000
}

proc wait_status(root: Path, previous: Int) -> Result[NtpGuestStatus] {
  let deadline = now_ms()? + 15000
  while now_ms()? < deadline {
    let file = fp"{root}/ntpd-rs.json"
    if file.exists()? {
      let status: NtpGuestStatus = json.read(file)?.require()?
      if status.state == "running" and status.ready and status.pid > 0 and status.pid != previous {
        return status
      }
    }
    time.sleep(50ms)
  }
  Err(NtpGuestError.Failed("ntpd-rs did not report supervisor readiness"))
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
  Err(NtpGuestError.Failed("ntp-ctl did not report a stratum"))
}

proc main(root: Path) [fs, process, env, time, io, error] {
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  assert generation.read_generation_receipt(/)?.profile.name == "qemu-self-hosting"
  let flags = p"/proc/cpuinfo".read_text()?
  for feature in ["aes", "pclmulqdq", "bmi1", "adx", "avx", "avx2"] {
    var found = false
    for line in flags.lines() {
      if line.starts_with("flags") and feature in line.split(" ") {
        found = true
      }
    }
    assert found, f"guest CPU lacks {feature}"
  }
  p"/etc/ntpd-rs".mkdir(true)?
  let nts_case = fp"{root}/inputs/nts-mode".exists()?
  let source = if nts_case {
    f"""mode = "nts"
address = "localhost:32460"
certificate-authority = "{root}/inputs/testca.pem"
"""
  } else {
    """mode = "server"
address = "127.0.0.1:32123"
"""
  }
  p"/etc/ntpd-rs/ntp.toml".write("""frequency-calibration-path = "/var/lib/ntpd-rs/frequency.json"
[observability]
log-level = "trace"
observation-path = "/run/ntpd-rs/observe"
observation-permissions = 0o644
[[source]]
""" + source + """
initial-poll-interval = 1
poll-interval-limits = { min = 1, max = 1 }
[synchronization]
minimum-agreeing-sources = 1
""")?
  let server_path = fp"{root}/inputs/ntp-clock-server"
  let raw_output = run.text $server_path "--raw"
  let raw_origin = raw_output.trim().parse_int_decimal()?
  let original = time.now()
  let origin = now_ms()?
  var groups: List[Int] = []
  var completed = false
  defer {
    let daemon_log = p"/run/ntp-proof-logs/ntpd-rs/current"
    if daemon_log.exists()? { print "NTP_DAEMON_LOG" daemon_log.read_text()? }
    let server_log = p"/run/ntp-oracle.log"
    if server_log.exists()? { print "NTP_SERVER_LOG" server_log.read_text()? }
    let cleanup = unix.shutdown_process_groups(groups, 2s, 100ms)?
    assert cleanup.remaining.is_empty(), "NTP proof retained process groups"
    linux.set_system_clock(original + now_ms()? - origin)?
    if completed { print "LAPUTA_NTP_GUEST_OK" }
  }
  let jump_case = fp"{root}/inputs/jump-mode".exists()?
  let pause_case = fp"{root}/inputs/pause-mode".exists()?
  if ! jump_case {
    let initial = if fp"{root}/inputs/ahead-mode".exists()? { original + 20000 } else { original - 20000 }
    linux.set_system_clock(initial)?
  }
  let run_dir = p"/run/ntp-proof"
  run_dir.mkdir(true)?
  let command = process.command_argv(/usr/bin/xsh, ["/usr/bin/xsh", "/usr/bin/xinit", "--", "supervise", "ntpd-rs"], env: {
    XINIT_SERVICE_DIR: "/usr/lib/xinit/services",
    XINIT_RUN_DIR: run_dir.display(),
    XINIT_LOG_ROOT: "/run/ntp-proof-logs",
  })
  let scanner = unix.spawn_process_group(command)?
  groups += [scanner.pid]
  let first = wait_status(run_dir, 0)?
  groups += [first.pid]
  check_identity(first.pid)?
  assert stratum()? == 16, "readiness was confused with synchronization"
  print "NTP_READY_UNSYNCED"
  if jump_case {
    time.sleep(2s)
    linux.set_system_clock(original + now_ms()? - origin - 5000)?
    let recovered = wait_status(run_dir, first.pid)?
    groups += [recovered.pid]
    check_identity(recovered.pid)?
    assert recovered.restarts > first.restarts
    print "NTP_JUMP_RESTART_READY"
  }
  let ready = p"/run/ntp-oracle-ready"
  let oracle = if nts_case { fp"{root}/inputs/nts-clock-server" } else { server_path }
  let args = if nts_case { [oracle.display(), f"{original}", f"{raw_origin}", ready.display(), fp"{root}/inputs".display()] } else { [oracle.display(), f"{original}", f"{raw_origin}", ready.display()] }
  let server = unix.spawn_process_group(process.command_argv(oracle, args, stdout: /run/ntp-oracle.log, stderr: /run/ntp-oracle.log))?
  groups += [server.pid]
  let server_deadline = now_ms()? + 10000
  while ! ready.exists()? and now_ms()? < server_deadline { time.sleep(50ms) }
  assert ready.exists()?, "controlled NTP server did not bind"
  if nts_case {
    let reject_deadline = now_ms()? + 45000
    var rejected = false
    while now_ms()? < reject_deadline {
      let log = p"/run/ntp-proof-logs/ntpd-rs/current"
      if log.exists()? and log.read_text()?.split("received invalid packet: Failed to decrypt NTS extension fields").len() >= 4 {
        assert stratum()? == 16, "tampered replies synchronized an NTS source"
        rejected = true
        break
      }
      time.sleep(100ms)
    }
    assert rejected, "NTS client did not reject three tampered responses"
    print "NTS_REJECTED_TAMPERED_REPLIES"
    p"/run/nts-oracle-authenticate".write("enabled")?
  }
  let deadline = now_ms()? + 120000
  var synced = false
  var report_at = now_ms()? + 10000
  while now_ms()? < deadline {
    let raw_now_output = run.text $server_path "--raw"
    let raw_now = raw_now_output.trim().parse_int_decimal()?
    let expected = original + raw_now - raw_origin
    let delta = time.now() - expected
    let current_stratum = stratum()?
    if current_stratum < 16 and (jump_case or (delta > -1500 and delta < 1500)) {
      synced = true
      break
    }
    if now_ms()? >= report_at {
      print f"NTP_PROGRESS stratum={current_stratum} delta_ms={delta}"
      if p"/run/ntp-oracle-count".exists()? { print "NTP_PACKETS" p"/run/ntp-oracle-count".read_text()? }
      report_at = now_ms()? + 10000
    }
    time.sleep(500ms)
  }
  if ! synced {
    run /usr/bin/ntp-ctl "status" "-c" "/etc/ntpd-rs/ntp.toml"
    if p"/run/ntp-oracle-count".exists()? { print "NTP_PACKETS" p"/run/ntp-oracle-count".read_text()? }
    let raw_now_output = run.text $server_path "--raw"
    let raw_now = raw_now_output.trim().parse_int_decimal()?
    let difference = time.now() - original - raw_now + raw_origin
    print f"NTP_CLOCK_DELTA_MS={difference}"
  }
  assert synced, "guest clock did not converge to the controlled NTP source"
  if jump_case {
    print "NTP_SOURCE_REACQUIRED"
  } else {
    assert "jumping" in p"/run/ntp-proof-logs/ntpd-rs/current".read_text()?, "expected a controlled clock step"
    print "NTP_CLOCK_SYNCED"
    process.kill(first.pid, signal: "KILL")?
    let replacement = wait_status(run_dir, first.pid)?
    groups += [replacement.pid]
    check_identity(replacement.pid)?
    assert replacement.restarts > first.restarts
    print "NTP_RESTART_READY"
    if pause_case {
      print "NTP_PAUSE_READY"
      io.flush_stdout()?
      time.sleep(2s)
      print "NTP_RESUME_OBSERVED"
      io.flush_stdout()?
      let before = p"/run/ntp-oracle-count".read_text()?.parse_int_decimal()?
      let pause_deadline = now_ms()? + 30000
      var replied = false
      while now_ms()? < pause_deadline {
        if p"/run/ntp-oracle-count".read_text()?.parse_int_decimal()? > before and stratum()? < 16 {
          replied = true
          break
        }
        time.sleep(100ms)
      }
      assert replied, "controlled source was not selected after a post-resume request"
      let running = wait_status(run_dir, 0)?
      check_identity(running.pid)?
      print "NTP_PAUSE_RECOVERED"
    }
  }
  completed = true
}

main(@args)?
