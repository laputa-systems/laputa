use pm.generation

error NtpGuestError = Failed(message: Str)

type NtpGuestStatus = {state: Str, pid: Int, ready: Bool, restarts: Int}

proc now_ms() -> Result[Int] { time.monotonic()? / 1000000 }

proc wait_status(root: Path, previous: Int) -> Result[NtpGuestStatus] {
  let deadline = now_ms()? + 15000
  while now_ms()? < deadline {
    let file = fp"{root}/ntpd-rs.json"
    if file.exists()? {
      let status: NtpGuestStatus = json.read(file)?.require()?
      if status.state == "running" and status.ready and status.pid > 0 and status.pid != previous { return status }
    }
    time.sleep(50ms)
  }
  Err(NtpGuestError.Failed("ntpd-rs did not report supervisor readiness"))
}

proc wait_sync() [fs, process, time, error] -> Result[Bool, Error] {
  let deadline = now_ms()? + 140000
  while now_ms()? < deadline {
    let output = run.text /usr/bin/ntp-ctl "status" "-c" "/etc/ntpd-rs/ntp.toml"
    for line in output.lines() {
      let trimmed = line.trim()
      if trimmed.starts_with("Stratum:") {
        let stratum = trimmed.replace("Stratum:", with: "").trim().parse_int_decimal()?
        if stratum < 16 and " [NTS]" in output { print $output; return Ok(true) }
      }
    }
    time.sleep(500ms)
  }
  Err(NtpGuestError.Failed("external NTS source did not synchronize"))
}

proc main(root: Path) [fs, process, net, env, time, io, error] {
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  assert generation.read_generation_receipt(p"/")?.profile.name == "qemu-self-hosting"
  let endpoint = fp"{root}/inputs/nts-endpoint".read_text()?.trim()
  var iface = ""
  for name in [entry.name ?? "" for entry in linux.network_dump()?.links] |> sort { if name != "lo" and iface == "" { iface = name } }
  assert iface != "", "guest has no network interface"
  linux.link_up(iface)?
  linux.set_ipv4_address(iface, "10.0.2.15", "255.255.255.0")?
  linux.add_default_ipv4_route("10.0.2.2", interface: iface)?
  p"/etc/resolv.conf".write("nameserver 10.0.2.3\n")?
  p"/etc/ntpd-rs".mkdir(true)?
  p"/etc/ntpd-rs/ntp.toml".write(f"""[observability]
log-level = "trace"
observation-path = "/run/ntpd-rs/observe"
observation-permissions = 0o644
[[source]]
mode = "nts"
address = "{endpoint}"
[synchronization]
minimum-agreeing-sources = 1
""")?
  let run_dir = p"/run/ntp-proof"
  run_dir.mkdir(true)?
  var groups: List[Int] = []
  var completed = false
  defer {
    let daemon_log = p"/run/ntp-proof-logs/ntpd-rs/current"
    if daemon_log.exists()? { print "NTP_DAEMON_LOG" daemon_log.read_text()? }
    let cleanup = unix.shutdown_process_groups(groups, 2s, 100ms)?
    assert cleanup.remaining.is_empty(), "NTP proof retained process groups"
    if completed { print "LAPUTA_NTP_GUEST_OK" }
  }
  let command = process.command_argv(p"/usr/bin/xsh", ["/usr/bin/xsh", "/usr/bin/xinit", "--", "supervise", "ntpd-rs"], env: {
    XINIT_SERVICE_DIR: "/usr/lib/xinit/services",
    XINIT_RUN_DIR: run_dir.display(),
    XINIT_LOG_ROOT: "/run/ntp-proof-logs",
  })
  let scanner = unix.spawn_process_group(command)?
  groups += [scanner.pid]
  let first = wait_status(run_dir, 0)?
  groups += [first.pid]
  assert wait_sync()?
  print "NTS_EXTERNAL_SYNCED"
  process.kill(first.pid, signal: "KILL")?
  let replacement = wait_status(run_dir, first.pid)?
  groups += [replacement.pid]
  assert replacement.restarts > first.restarts
  assert wait_sync()?
  print "NTS_EXTERNAL_RESTART_SYNCED"
  completed = true
}

main(@args)?
