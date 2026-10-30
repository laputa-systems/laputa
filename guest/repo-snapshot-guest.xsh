use pm.remote
use pm.repo_snapshot

error GuestTrustError = Failed(phase: Str, message: Str)

const GUEST_STORE_DEV = "/dev/vda"
const GUEST_STORE_MNT = "/store"
const GUEST_PHASE_FILE = "/store/repo-phase"
const GUEST_MARKER = "LAPUTA_REPO_GUEST"

proc say(message: Str) [fs, error] {
  p"/dev/console".write(bytes.from_text(f"{GUEST_MARKER} {message}\n"))?
}

proc fail_phase(phase: Str, message: Str) [fs, error] {
  say(f"FAIL {phase} {message}")?
  return Err(GuestTrustError.Failed(phase:, message:))
}

proc wait_for(path_value: Path, phase: Str, seconds: Int) [fs, time, error] {
  var elapsed = 0
  while ! path_value.exists()? {
    guard elapsed < seconds else {
      return fail_phase(phase, f"missing {path_value.display()} after {seconds}s")
    }

    time.sleep(1s)?
    elapsed += 1
  }
}

proc insmod_one(name: Str, phase: Str) [fs, process, error] {
  match linux.insmod(fp"/lib/modules/{name}.ko") {
    Ok(_) => {},
    Err(problem) => {
      var seen = ""
      match fs.children(fp"/lib/modules") {
        Ok(entries) => {
          for entry in entries {
            seen = f"{seen} {entry.name}"
          }
        },
        Err(_) => {
          seen = "<unlistable>"
        },
      }

      return fail_phase(phase, f"insmod {name}: {problem.message}; exists={fp"/lib/modules/{name}.ko".exists()?}; entries={seen}")
    },
  }
}

proc load_drivers(phase: Str) [fs, process, error] {
  for name in [
    "virtio_ring",
    "virtio",
    "virtio_pci_modern_dev",
    "virtio_pci_legacy_dev",
    "virtio_pci",
    "virtio_blk",
    "failover",
    "net_failover",
    "virtio_net",
    "crc16",
    "mbcache",
    "jbd2",
    "ext4",
  ] {
    insmod_one(name, phase)?
  }
}

proc mount_store(phase: Str) [fs, process, time, error] {
  wait_for_dev_vda(phase)?
  fp"{GUEST_STORE_MNT}".mkdir(parents: true)
  match linux.mount(bytes.from_text(GUEST_STORE_DEV), fp"{GUEST_STORE_MNT}", fstype: "ext4") {
    Ok(_) => {},
    Err(problem) => return fail_phase(phase, f"mount store: {problem.message}"),
  }
}

proc wait_for_dev_vda(phase: Str) [fs, time, error] {
  var elapsed = 0
  while ! p"/dev/vda".exists()? {
    guard elapsed < 30 else {
      var seen = ""
      match fs.children(fp"/dev") {
        Ok(entries) => {
          for entry in entries {
            seen = f"{seen} {entry.name}"
          }
        },
        Err(_) => {
          seen = "<unlistable>"
        },
      }

      var mounts = "<unreadable>"
      match p"/proc/mounts".read_text() {
        Ok(text) => {
          mounts = text
        },
        Err(_) => {},
      }

      return fail_phase(phase, f"missing /dev/vda after 30s; dev=[{seen}] mounts=[{mounts}]")
    }

    time.sleep(1s)?
    elapsed += 1
  }
}

proc bring_up_net(phase: Str) [fs, process, net, error] {
  var iface = ""
  for entry in linux.interfaces()? {
    if entry.name != "lo" and iface == "" {
      iface = entry.name
    }
  }

  guard iface != "" else {
    return fail_phase(phase, "no non-loopback interface for the fixture server route")
  }

  match linux.link_up(iface) {
    Ok(_) => {},
    Err(problem) => return fail_phase(phase, f"link up: {problem.message}"),
  }

  match linux.set_ipv4_address(iface, "10.0.2.15", "255.255.255.0") {
    Ok(_) => {},
    Err(problem) => return fail_phase(phase, f"set address: {problem.message}"),
  }

  match linux.add_default_ipv4_route("10.0.2.2", interface: iface) {
    Ok(_) => {},
    Err(problem) => return fail_phase(phase, f"add route: {problem.message}"),
  }
}

proc read_phase() [fs, error] -> Result[Str, Error] {
  guard fp"{GUEST_PHASE_FILE}".exists()? else {
    return "0"
  }

  fp"{GUEST_PHASE_FILE}".read_text()?.trim()
}

proc write_phase(value: Str) [fs, error] {
  fp"{GUEST_PHASE_FILE}".write(bytes.from_text(f"{value}\n"))?
  fs.fsync(fp"{GUEST_PHASE_FILE}")?
  fs.fsync(fp"{GUEST_STORE_MNT}")?
}

proc cmdline_value(key: Str) [fs, error] -> Result[Str, Error] {
  for field in p"/proc/cmdline".read_text()?.split(" ") {
    guard field.starts_with(f"{key}=") else {
      continue
    }

    return field.byte_slice(key.byte_len() + 1, field.byte_len()).trim()
  }

  Err(GuestTrustError.Failed(phase: "cmdline", message: f"missing {key} on the kernel command line"))
}

proc main() [fs, process, time, net, error, io] {
  p"/proc".mkdir(parents: true)
  p"/sys".mkdir(parents: true)
  linux.mount(bytes.from_text("devtmpfs"), p"/dev", fstype: "devtmpfs")?
  linux.mount(bytes.from_text("proc"), p"/proc", fstype: "proc")?
  linux.mount(bytes.from_text("sysfs"), p"/sys", fstype: "sysfs")?
  load_drivers("boot")?
  mount_store("boot")?
  bring_up_net("boot")?
  let url = cmdline_value("repo_url")?
  let keys = [p"/guest/signing-key".read_bytes()?, p"/guest/next-key".read_bytes()?]
  let state = p"/store/state"
  let phase = read_phase()?
  if phase == "0" {
    let index = remote.load_verified_remote_index(url, p"/store/out", keys, 1995000000, state.display())?
    guard index.len() == 1 and index[0].name == "fixture" else {
      return fail_phase("accept", "signed index had unexpected contents")
    }
    let accepted = repo_snapshot.snapshot_read_accepted(repo_snapshot.snapshot_state_paths(state, url))?
    guard accepted != null else { return fail_phase("accept", "missing accepted state") }
    guard accepted.generation == "2" else { return fail_phase("accept", "wrong accepted generation") }
    match remote.load_verified_remote_index(f"{url}/tampered", p"/store/tampered-out", keys, 1995000000, state.display()) {
      Ok(_) => return fail_phase("tamper", "tampered index was accepted"),
      Err(problem) => guard "does not match signed snapshot metadata" in problem.message else { return fail_phase("tamper", problem.message) },
    }
    guard ! p"/store/tampered-out".exists()? else { return fail_phase("tamper", "tampered index was cached") }
    say("ACCEPT_AND_TAMPER_OK generation=2")?
    write_phase("1")?
    linux.reboot()?
    return
  }
  guard phase == "1" else { return fail_phase("boot", "unknown phase") }
  match remote.load_verified_remote_index(url, p"/store/rollback-out", keys, 1995000000, state.display()) {
    Ok(_) => return fail_phase("rollback", "older snapshot was accepted after reboot"),
    Err(problem) => guard "accepted snapshot" in problem.message else { return fail_phase("rollback", problem.message) },
  }
  let accepted = repo_snapshot.snapshot_read_accepted(repo_snapshot.snapshot_state_paths(state, url))?
  guard accepted != null else { return fail_phase("rollback", "accepted state disappeared") }
  guard accepted.generation == "2" else { return fail_phase("rollback", "accepted generation changed") }
  guard ! p"/store/rollback-out".exists()? else { return fail_phase("rollback", "older index was cached") }
  say("ROLLBACK_REJECTED generation=2")?
  linux.poweroff()?
}

main()?
