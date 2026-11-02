use pm.generation

error FrequencyGuestError = Failed(message: Str)
type FrequencyStatus = {state: Str, pid: Int, ready: Bool, restarts: Int}

proc now_ms() -> Result[Int] { time.monotonic()? / 1000000 }

proc wait_ready(root: Path, previous: Int) -> Result[FrequencyStatus] {
  let deadline = now_ms()? + 20000
  while now_ms()? < deadline {
    let file = fp"{root}/ntpd-rs.json"
    if file.exists()? {
      let status: FrequencyStatus = json.read(file)?.require()?
      if status.state == "running" and status.ready and status.pid > 0 and status.pid != previous { return status }
    }
    time.sleep(100ms)
  }
  Err(FrequencyGuestError.Failed("ntpd-rs did not become ready"))
}

proc stratum() -> Result[Int] {
  let output = run.text /usr/bin/ntp-ctl "status" "-c" "/etc/ntpd-rs/ntp.toml"
  for line in output.lines() {
    let text = line.trim()
    if text.starts_with("Stratum:") { return text.replace("Stratum:", with: "").trim().parse_int_decimal()? }
  }
  Err(FrequencyGuestError.Failed("ntp-ctl did not report a stratum"))
}

proc main(root: Path) [fs, process, env, time, io, error] {
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  assert generation.read_generation_receipt(p"/")?.profile.name == "qemu-self-hosting"
  let output = p"/run/frequency-output"
  output.mkdir(true)?
  linux.mount(b"/dev/vdc", output, fstype: "ext4", options: ["nosuid", "nodev"])?
  let saved_dir = fp"{output}/ntpd-rs"
  if ! saved_dir.exists()? {
    saved_dir.mkdir(true)?
    saved_dir.chmod(0o700)?
    fs.chown(saved_dir, user.by_uid(123)?)?
    fs.chgrp(saved_dir, group.by_gid(123)?)?
  }
  p"/var/lib/ntpd-rs".mkdir(true)?
  linux.mount(bytes.from_text(saved_dir.display()), p"/var/lib/ntpd-rs", options: ["bind"])?
  let saved = p"/var/lib/ntpd-rs/frequency.json"
  let second_boot = fp"{output}/first-boot-complete".exists()?
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
  let oracle = fp"{root}/inputs/ntp-clock-server"
  let check = fp"{root}/inputs/ntp-frequency-check"
  if second_boot {
    run $check "unrestored" $saved
    print "FREQUENCY_REBOOT_STARTS_UNCALIBRATED"
  }
  let raw_origin = (run.text $oracle "--raw").trim().parse_int_decimal()?
  let original = time.now()
  let origin = now_ms()?
  var groups: List[Int] = []
  var completed = false
  defer {
    let log = p"/run/frequency-logs/ntpd-rs/current"
    if log.exists()? { print "FREQUENCY_DAEMON_LOG" log.read_text()? }
    let cleanup = unix.shutdown_process_groups(groups, 2s, 100ms)?
    assert cleanup.remaining.is_empty(), "frequency proof retained process groups"
    linux.set_system_clock(original + now_ms()? - origin)?
    fs.sync()?
    if completed { print "LAPUTA_NTP_GUEST_OK" }
  }
  let run_dir = p"/run/frequency-proof"
  run_dir.mkdir(true)?
  let scanner = unix.spawn_process_group(process.command_argv(p"/usr/bin/xsh", ["/usr/bin/xsh", "/usr/bin/xinit", "--", "supervise", "ntpd-rs"], env: {
    XINIT_SERVICE_DIR: "/usr/lib/xinit/services", XINIT_RUN_DIR: run_dir.display(), XINIT_LOG_ROOT: "/run/frequency-logs",
  }))?
  groups += [scanner.pid]
  let first = wait_ready(run_dir, 0)?
  groups += [first.pid]
  assert stratum()? == 16, "calibration must not signal synchronization"
  if second_boot {
    run $check "restored" $saved
    assert "restored clock frequency calibration" in p"/run/frequency-logs/ntpd-rs/current".read_text()?
    print "FREQUENCY_REBOOT_RESTORED_UNSYNCED"
  } else {
    assert ! saved.exists()?, "first boot already had calibration"
    print "FREQUENCY_FIRST_BOOT_UNSYNCED"
  }
  let ready = p"/run/frequency-oracle-ready"
  let server = unix.spawn_process_group(process.command_argv(oracle, [oracle.display(), f"{original}", f"{raw_origin}", ready.display(), "100"], stdout: p"/run/frequency-oracle.log", stderr: p"/run/frequency-oracle.log"))?
  groups += [server.pid]
  let deadline = now_ms()? + 170000
  var learned = false
  while now_ms()? < deadline {
    if stratum()? < 16 {
      if second_boot { learned = true; break }
      if saved.exists()? {
        let valid = run.status $check "saved" $saved
        if valid.ok { learned = true; break }
      }
    }
    time.sleep(500ms)
  }
  assert learned, "frequency calibration or source selection did not complete"
  if second_boot {
    print "FREQUENCY_RESELECTED_SOURCE"
  } else {
    print "FREQUENCY_LEARNED_AND_SAVED"
    let cleanup = unix.shutdown_process_groups([server.pid], 2s, 100ms)?
    assert cleanup.remaining.is_empty(), "frequency oracle did not stop"
    process.kill(first.pid, signal: "KILL")?
    let restarted = wait_ready(run_dir, first.pid)?
    groups += [restarted.pid]
    assert stratum()? == 16, "restart without peer was synchronized"
    run $check "restored" $saved
    assert "restored clock frequency calibration" in p"/run/frequency-logs/ntpd-rs/current".read_text()?
    print "FREQUENCY_RESTART_RESTORED_UNSYNCED"
    let marker = fp"{output}/first-boot-complete"
    marker.write("complete\n")?
    fs.fsync(marker)?
    fs.fsync(output)?
  }
  completed = true
}

main(@args)?
