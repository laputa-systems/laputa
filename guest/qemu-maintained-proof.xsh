#!/bin/xsh

proc listener_ready() -> Result[Bool] {
  let status = p"/run/xinit/dropbear.json"
  return false unless status.exists()?
  json.get(json.read(status)?, ["state"], "down").require(Str)? == "running"
}

proc service_state(name: Str) -> Result[Str] {
  let status = fp"/run/xinit/{name}.json"
  wait until status.exists()? within 30s every 100ms
  json.get(json.read(status)?, ["state"], "").require(Str)?
}

proc unit_summary() -> Result[Str] {
  var parts: List[Str] = []
  for item in g"/run/xinit/*.json" {
    let value = json.read(item)?
    let name = json.get(value, ["name"], "").require(Str)?
    if name != "" {
      let state = json.get(value, ["state"], "").require(Str)?
      let restarts = json.get(value, ["restarts"], 0).require(Int)?
      parts += [f"{name}={state}/{restarts}"]
    }
  }
  parts.join(" ")
}

proc path_summary() -> Result[Str] {
  var marks: List[Str] = []
  for item in [p"/var/lib/dhcpc", p"/run/dhcpc", p"/run/dhcpc/eth0.status", p"/etc/resolv.conf", p"/usr/bin/dhcpc", p"/usr/bin/syslogd"] {
    let present = item.exists()?
    marks += [f"{item.display()}={present}"]
  }
  marks.join(" ")
}

proc lease_summary() -> Result[Str] {
  let status = p"/run/dhcpc/eth0.status"
  return "absent" unless status.exists()?
  let text = status.read_text()?.trim()
  if text == "" {
    return "empty"
  }
  if text.byte_len() > 500 {
    return text[..500]
  }
  text
}

proc wait_state(name: Str, want: Str) {
  var waited = 0
  while waited < 30 {
    if service_state(name)? == want {
      return
    }
    time.sleep(1s)?
    waited += 1
  }
  p"/dev/console".write(f"LAPUTA_MAINTAINED_STATUS units: {unit_summary()?}\n")
  p"/dev/console".write(f"LAPUTA_MAINTAINED_STATUS paths: {path_summary()?}\n")
  p"/dev/console".write(f"LAPUTA_MAINTAINED_STATUS lease: {lease_summary()?}\n")
  fail f"{name} never reached {want}"
}

proc supervised_network() -> Result[Str] {
  wait_state("logger", "running")
  wait_state("dhcp-eth0", "running")
  let lease = p"/run/dhcpc/eth0.status"
  wait until lease.exists()? within 30s every 100ms
  var leased = ""
  var waited = 0
  while waited < 60 {
    leased = json.get(json.read(lease)?, ["state"], "").require(Str)?
    if leased == "bound" {
      break
    }
    time.sleep(1s)?
    waited += 1
  }
  guard leased == "bound" else { fail f"dhcp lease is {leased}, not bound" }
  let resolv = p"/etc/resolv.conf".read_text()?
  guard "# Managed by dhcpc" in resolv else { fail "resolv.conf is not owned by dhcpc" }
  guard "nameserver" in resolv else { fail "resolv.conf names no server" }
  p"/dev/console".write("LAPUTA_MAINTAINED_LOGGER_OK supervised syslog is running\n")
  p"/dev/console".write(f"LAPUTA_MAINTAINED_DHCP_OK lease is {leased} with a managed resolver\n")
  f"logger=running dhcp-eth0=running lease={leased}\n"
}

proc run_proof() {
  return unless "LAPUTA_MAINTAINED_PROOF_FLAG=1" in p"/proc/cmdline".read_text()?

  let cmdline = p"/proc/cmdline".read_text()?
  if "LAPUTA_BOOT_POLICY_PROOF=1" in cmdline {
    guard linux.sysctl_get("vm.swappiness")?.trim() == "17" else {
      fail "persistent sysctl configuration was not applied"
    }
    p"/dev/console".write("LAPUTA_BOOT_POLICY_PROOF_OK persistent sysctl applied\n")
  }
  if "LAPUTA_FIREWALL_FAILURE_PROOF=1" in cmdline {
    let firewall = p"/run/xinit/firewall.json"
    time.sleep(3s)
    if firewall.exists()? {
      guard json.get(json.read(firewall)?, ["state"], "missing").require(Str)? != "running" else {
        fail "invalid firewall unexpectedly started"
      }
    }
    guard ! listener_ready()? else { fail "dropbear started after firewall failure" }
    let listener = p"/run/xinit/dropbear.json"
    if listener.exists()? {
      guard json.get(json.read(listener)?, ["pid"], 0).require(Int)? == 0 else {
        fail "dropbear process started after firewall failure"
      }
    }
    p"/dev/console".write("LAPUTA_FIREWALL_FAILURE_PROOF_OK listener stayed down\n")
    process.kill(1, signal: "USR2")?
    return
  }

  let applied = p"/etc/laputa/first-boot/applied".read_text()?
  let operator = applied.lines() |> where .starts_with("operator ") |> collect
  guard operator.len() == 1 else { fail "one provisioned operator required" }
  let name = operator[0].split(" ")[1]
  let keys = fp"/home/{name}/.ssh/authorized_keys"
  guard keys.read_text()?.trim() != "" else { fail "operator authorized keys required" }
  let host_key = p"/etc/dropbear/dropbear_ed25519_host_key"
  wait until host_key.exists()? within 30s every 100ms
  guard host_key.read_bytes()?.len() > 0 else { fail "persistent host key required" }
  wait until listener_ready()? within 30s every 100ms
  wait until p"/run/laputa-health.json".exists()? within 30s every 100ms
  let files = [host_key, keys, p"/etc/passwd", p"/etc/group", p"/etc/shadow", p"/etc/hostname", p"/etc/laputa/first-boot/applied"]
  let hashes = [hash.sha256(item)?.hex() for item in files].join("\n") + "\n" + supervised_network()?
  let baseline = p"/var/lib/laputa/maintained-proof-before-reboot"
  if baseline.exists()? {
    let prior = baseline.read_text()?
    if prior == hashes {
      p"/dev/console".write("LAPUTA_MAINTAINED_PROOF_OK identity survived guest reboot\n")
    } else {
      p"/dev/console".write(f"LAPUTA_MAINTAINED_BASELINE_MISMATCH prior={prior} current={hashes}\n")
      fail "identity changed across reboot"
    }
  } else {
    baseline.write(hashes)
    fs.fsync(baseline)
    fs.fsync(baseline.parent)
    p"/dev/console".write("LAPUTA_MAINTAINED_PROOF_READY rebooting through pid 1\n")
    process.kill(1, signal: "TERM")?
  }
}

proc main() -> Result[Unit, Error] {
  match run_proof() {
    Ok(_) => {}
    Err(problem) => {
      p"/dev/console".write(f"LAPUTA_MAINTAINED_PROOF_FAILED {problem.message}\n")
      return Err(problem)
    }
  }
}
