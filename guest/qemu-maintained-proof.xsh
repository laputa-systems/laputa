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

proc supervised_network() -> Result[Str] {
  wait until service_state("logger")? == "running" within 30s every 100ms
  wait until service_state("dhcp-eth0")? == "running" within 30s every 100ms
  let lease = p"/run/dhcpc/eth0.status"
  wait until lease.exists()? within 30s every 100ms
  let state = json.get(json.read(lease)?, ["state"], "").require(Str)?
  guard state == "bound" else { fail f"dhcp lease is {state}, not bound" }
  let resolv = p"/etc/resolv.conf".read_text()?
  guard "# Managed by dhcpc" in resolv else { fail "resolv.conf is not owned by dhcpc" }
  guard "nameserver" in resolv else { fail "resolv.conf names no server" }
  p"/dev/console".write("LAPUTA_MAINTAINED_LOGGER_OK supervised syslog is running\n")
  p"/dev/console".write(f"LAPUTA_MAINTAINED_DHCP_OK lease is {state} with a managed resolver\n")
  f"logger=running dhcp-eth0=running lease={state}\n"
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
    guard baseline.read_text()? == hashes else { fail "identity changed across reboot" }
    p"/dev/console".write("LAPUTA_MAINTAINED_PROOF_OK identity survived guest reboot\n")
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
