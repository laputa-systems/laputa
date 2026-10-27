#!/bin/xsh
##! In-guest signed trust proof: bootstrap from seeds, offline update, HTTPS
##! update, reboot replay, and power-cut recovery on a durable store disk.
##! Runs as /init inside the guest initramfs; the host driver in
##! tests/system/trust_guest.xsh owns QEMU, the TLS server, and the verdict.
##! Every phase is idempotent: the phase file only skips completed work, and
##! re-running any phase converges through journal recovery or resume.
use trust.store as trust_store
use trust.update as trust_update

error GuestTrustError = Failed(phase: Str, message: Str)

const GUEST_STORE_DEV = "/dev/vda"
const GUEST_STORE_MNT = "/store"
const GUEST_PHASE_FILE = "/store/trust-phase"
const GUEST_MARKER = "LAPUTA_TRUST_GUEST"

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

## trust_url= and trust_mode= arrive on the kernel command line from the host.
proc cmdline_value(key: Str) [fs, error] -> Result[Str, Error] {
  for field in p"/proc/cmdline".read_text()?.split(" ") {
    guard field.starts_with(f"{key}=") else {
      continue
    }

    return field.byte_slice(key.byte_len() + 1, field.byte_len()).trim()
  }

  Err(GuestTrustError.Failed(phase: "cmdline", message: f"missing {key} on the kernel command line"))
}

proc journal_present(paths: trust_store.TrustStorePaths) [fs, error] -> Result[Bool, Error] {
  let journal = trust_store.trust_store_read_journal(paths)?
  journal.present
}

proc run_phase_zero(paths: trust_store.TrustStorePaths) [fs, process, time, error] {
  let before = trust_update.trust_status(p"/")?
  guard before.initialized.require(Bool)? == false else {
    say("FAIL phase0 expected an uninitialized store on first boot")?
    return Err(GuestTrustError.Failed(phase: "phase0", message: "expected an uninitialized store on first boot"))
  }

  say("PHASE0_BEGIN")?
  let applied = trust_update.trust_update_from_dir(p"/", p"/releases/release-b")?
  guard applied.generation.require(Str)? == "2" else {
    say("FAIL phase0 offline update did not reach generation 2")?
    return Err(GuestTrustError.Failed(phase: "phase0", message: "offline update did not reach generation 2"))
  }

  let after = trust_update.trust_status(p"/")?
  guard after.generation.require(Str)? == "2" and after.accepted.require(Str)? == "2" else {
    say("FAIL phase0 status does not report generation 2 after offline update")?
    return Err(GuestTrustError.Failed(phase: "phase0", message: "status does not report generation 2"))
  }

  say(f"PHASE0_OK generation=2 bundle={after.bundle_sha256.require(Str)?} policy={after.policy_sha256.require(Str)?}")?
  write_phase("1")?
}

proc run_phase_one(
  paths: trust_store.TrustStorePaths,
  url: Str,
  mode: Str,
) [fs, process, time, net, error] {
  let active = trust_store.trust_store_read_active(paths)?
  say(f"ENTRY phase=1 active={active} journal={journal_present(paths)?}")?
  guard active == "2" else {
    say("FAIL phase1 expected active generation 2 on entry")?
    return Err(GuestTrustError.Failed(phase: "phase1", message: "expected active generation 2 on entry"))
  }

  say(f"FETCH_START url={url}")?
  let applied = trust_update.trust_update_from_url(p"/", url)?
  guard applied.generation.require(Str)? == "3" else {
    say("FAIL phase1 HTTPS update did not reach generation 3")?
    return Err(GuestTrustError.Failed(phase: "phase1", message: "HTTPS update did not reach generation 3"))
  }

  let after = trust_update.trust_status(p"/")?
  guard after.generation.require(Str)? == "3" and after.accepted.require(Str)? == "3" and after.pending.require(Str)? == "none" else {
    say("FAIL phase1 status does not report a clean generation 3 after HTTPS update")?
    return Err(GuestTrustError.Failed(phase: "phase1", message: "status is not a clean generation 3"))
  }

  say(f"PHASE1_OK generation=3 bundle={after.bundle_sha256.require(Str)?} policy={after.policy_sha256.require(Str)?}")?
  write_phase("2")?
}

proc run_phase_two(paths: trust_store.TrustStorePaths) [fs, time, error] {
  let active = trust_store.trust_store_read_active(paths)?
  say(f"ENTRY phase=2 active={active} journal={journal_present(paths)?}")?
  guard active == "3" else {
    say("FAIL phase2 expected active generation 3 on replay")?
    return Err(GuestTrustError.Failed(phase: "phase2", message: "expected active generation 3 on replay"))
  }

  let status = trust_update.trust_status(p"/")?
  guard status.accepted.require(Str)? == "3" and status.pending.require(Str)? == "none" and status.atomic_capable.require(Bool)? == true else {
    say("FAIL phase2 replayed status is not a clean generation 3")?
    return Err(GuestTrustError.Failed(phase: "phase2", message: "replayed status is not clean"))
  }

  say(f"REPLAY_OK generation=3 bundle={status.bundle_sha256.require(Str)?} policy={status.policy_sha256.require(Str)?}")?
}

proc main() [fs, process, time, net, error, io] {
  p"/proc".mkdir(parents: true)
  p"/sys".mkdir(parents: true)
  match linux.mount(bytes.from_text("devtmpfs"), p"/dev", fstype: "devtmpfs") {
    Ok(_) => {},
    Err(problem) => return fail_phase("boot", f"mount devtmpfs: {problem.message}"),
  }

  match linux.mount(bytes.from_text("proc"), p"/proc", fstype: "proc") {
    Ok(_) => {},
    Err(problem) => return fail_phase("boot", f"mount proc: {problem.message}"),
  }

  match linux.mount(bytes.from_text("sysfs"), p"/sys", fstype: "sysfs") {
    Ok(_) => {},
    Err(problem) => return fail_phase("boot", f"mount sysfs: {problem.message}"),
  }

  load_drivers("boot")?
  mount_store("boot")?
  fp"/store/trust".mkdir(parents: true)
  bring_up_net("boot")?

  let url = cmdline_value("trust_url")?
  let mode = cmdline_value("trust_mode")?
  let paths = trust_store.trust_store_paths(p"/")
  let phase = read_phase()?
  say(f"BOOT phase={phase} mode={mode}")?

  if phase == "0" {
    run_phase_zero(paths)?
    say("REBOOTING")?
    linux.reboot()?
    return
  }

  if phase == "1" {
    run_phase_one(paths, url, mode)?
    if mode == "replay" {
      say("REBOOTING")?
      linux.reboot()?
      return
    }

    say("POWEROFF")?
    linux.poweroff()?
    return
  }

  guard phase == "2" else {
    say("FAIL boot refusing an unknown trust phase")?
    return Err(GuestTrustError.Failed(phase: "boot", message: "unknown trust phase"))
  }

  run_phase_two(paths)?
  say("POWEROFF")?
  linux.poweroff()?
}

main()?
