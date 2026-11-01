use pm.generation

error ChronyOracleError = Failed(message: Str)
type ChronyStatus = {state: Str, pid: Int, ready: Bool}

proc now_ms() -> Result[Int] {
  time.monotonic()? / 1000000
}

proc main(root: Path) [fs, process, env, time, io, error] {
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  assert generation.read_generation_receipt(/)?.profile.name == "qemu-self-hosting"
  let oracle = fp"{root}/inputs/ntp-clock-server"
  let client = fp"{root}/inputs/chronyc"
  let raw_origin = (run.text $oracle "--raw").trim().parse_int_decimal()?
  let original = time.now()
  let origin = now_ms()?
  var groups: List[Int] = []
  var completed = false
  defer {
    let log = p"/run/chrony-oracle-logs/chrony-oracle/current"
    if log.exists()? { print "CHRONY_LOG" log.read_text()? }
    let cleanup = unix.shutdown_process_groups(groups, 2s, 100ms)?
    assert cleanup.remaining.is_empty(), "chrony proof retained process groups"
    linux.set_system_clock(original + now_ms()? - origin)?
    if completed { print "LAPUTA_NTP_GUEST_OK" }
  }
  let ahead = fp"{root}/inputs/ahead-mode".exists()?
  let slew_case = fp"{root}/inputs/slew-mode".exists()?
  linux.set_system_clock(if slew_case { original - 80 } else if ahead { original + 20000 } else { original - 20000 })?
  p"/run/chrony-oracle.conf".write("""server 127.0.0.1 port 32123 minpoll 1 maxpoll 1 iburst
makestep 1.0 3
port 0
cmdport 32461
bindcmdaddress 127.0.0.1
pidfile /run/chrony-oracle.pid
""")?
  let run_dir = p"/run/chrony-oracle"
  run_dir.mkdir(true)?
  let command = process.command_argv(/usr/bin/xsh, ["/usr/bin/xsh", "/usr/bin/xinit", "--", "supervise", "chrony-oracle"], env: {
    XINIT_SERVICE_DIR: fp"{root}/inputs".display(),
    XINIT_RUN_DIR: run_dir.display(),
    XINIT_LOG_ROOT: "/run/chrony-oracle-logs",
  })
  let scanner = unix.spawn_process_group(command)?
  groups += [scanner.pid]
  let ready_deadline = now_ms()? + 15000
  var ready = false
  while now_ms()? < ready_deadline {
    let status_file = fp"{run_dir}/chrony-oracle.json"
    if status_file.exists()? {
      let status: ChronyStatus = json.read(status_file)?.require()?
      if status.state == "running" and status.ready and status.pid > 0 {
        groups += [status.pid]
        ready = true
        break
      }
    }
    time.sleep(50ms)
  }
  assert ready, "chrony did not signal readiness"
  let before = run.text $client "-h" "127.0.0.1" "-p" "32461" "tracking"
  assert "Not synchronised" in before, "chrony readiness was confused with synchronization"
  print "CHRONY_READY_UNSYNCED"
  let server_ready = p"/run/ntp-oracle-ready"
  let server = unix.spawn_process_group(process.command_argv(oracle, [oracle.display(), f"{original}", f"{raw_origin}", server_ready.display()], stdout: /run/ntp-oracle.log, stderr: /run/ntp-oracle.log))?
  groups += [server.pid]
  let deadline = now_ms()? + (if slew_case { 300000 } else { 120000 })
  var synced = false
  var previous_delta = -80
  var largest_change = 0
  while now_ms()? < deadline {
    let raw_now = (run.text $oracle "--raw").trim().parse_int_decimal()?
    let delta = time.now() - original - raw_now + raw_origin
    let tracking = run.text $client "-h" "127.0.0.1" "-p" "32461" "tracking"
    let change = if delta > previous_delta { delta - previous_delta } else { previous_delta - delta }
    if change > largest_change { largest_change = change }
    previous_delta = delta
    let window = if slew_case { 15 } else { 1500 }
    if "Leap status     : Normal" in tracking and delta > -window and delta < window {
      synced = true
      break
    }
    time.sleep(500ms)
  }
  assert synced, "chrony did not converge to the controlled NTP source"
  let stepped = "System clock was stepped by" in p"/run/chrony-oracle-logs/chrony-oracle/current".read_text()?
  if slew_case {
    assert ! stepped, "chrony stepped a sub-second offset"
    print f"CHRONY_SLEW_CONVERGED largest_sample_change_ms={largest_change}"
  } else {
    assert stepped, "chrony did not step the clock"
    print "CHRONY_CLOCK_SYNCED"
  }
  completed = true
}

main(@args)?
