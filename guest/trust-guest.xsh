#!/bin/xsh
##! In-guest signed trust proof: bootstrap from seeds, offline update, HTTPS
##! update, reboot replay, and power-cut recovery on a durable store disk.
##! Runs as /init inside the guest initramfs; the host driver in
##! tests/system/trust_guest.xsh owns QEMU, the TLS server, and the verdict.
##! Every phase is idempotent: the phase file only skips completed work, and
##! re-running any phase converges through journal recovery or resume.
use guest.bootstrap as guest_bootstrap
use trust.store as trust_store
use trust.update as trust_update

const GUEST_CONTEXT = {marker: "LAPUTA_TRUST_GUEST", phase_file: "/store/trust-phase"}

proc journal_present(paths: trust_store.TrustStorePaths) [fs, error] -> Result[Bool, Error] {
  let journal = trust_store.trust_store_read_journal(paths)?
  journal.present
}

proc run_phase_zero(paths: trust_store.TrustStorePaths) [fs, process, time, error] {
  let before = trust_update.trust_status(p"/")?
  guard before.initialized.require(Bool)? == false else {
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "FAIL phase0 expected an uninitialized store on first boot")?
    return Err(guest_bootstrap.GuestTrustError.Failed(phase: "phase0", message: "expected an uninitialized store on first boot"))
  }

  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "PHASE0_BEGIN")?
  let applied = trust_update.trust_update_from_dir(p"/", p"/releases/release-b")?
  guard applied.generation.require(Str)? == "2" else {
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "FAIL phase0 offline update did not reach generation 2")?
    return Err(guest_bootstrap.GuestTrustError.Failed(phase: "phase0", message: "offline update did not reach generation 2"))
  }

  let after = trust_update.trust_status(p"/")?
  guard after.generation.require(Str)? == "2" and after.accepted.require(Str)? == "2" else {
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "FAIL phase0 status does not report generation 2 after offline update")?
    return Err(guest_bootstrap.GuestTrustError.Failed(phase: "phase0", message: "status does not report generation 2"))
  }

  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, f"PHASE0_OK generation=2 bundle={after.bundle_sha256.require(Str)?} policy={after.policy_sha256.require(Str)?}")?
  guest_bootstrap.guest_bootstrap_write_phase(GUEST_CONTEXT, "1")?
}

proc run_phase_one(
  paths: trust_store.TrustStorePaths,
  url: Str,
  mode: Str,
) [fs, process, time, net, error] {
  let active = trust_store.trust_store_read_active(paths)?
  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, f"ENTRY phase=1 active={active} journal={journal_present(paths)?}")?
  guard active == "2" else {
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "FAIL phase1 expected active generation 2 on entry")?
    return Err(guest_bootstrap.GuestTrustError.Failed(phase: "phase1", message: "expected active generation 2 on entry"))
  }

  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, f"FETCH_START url={url}")?
  let applied = trust_update.trust_update_from_url(p"/", url)?
  guard applied.generation.require(Str)? == "3" else {
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "FAIL phase1 HTTPS update did not reach generation 3")?
    return Err(guest_bootstrap.GuestTrustError.Failed(phase: "phase1", message: "HTTPS update did not reach generation 3"))
  }

  let after = trust_update.trust_status(p"/")?
  guard after.generation.require(Str)? == "3" and after.accepted.require(Str)? == "3" and after.pending.require(Str)? == "none" else {
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "FAIL phase1 status does not report a clean generation 3 after HTTPS update")?
    return Err(guest_bootstrap.GuestTrustError.Failed(phase: "phase1", message: "status is not a clean generation 3"))
  }

  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, f"PHASE1_OK generation=3 bundle={after.bundle_sha256.require(Str)?} policy={after.policy_sha256.require(Str)?}")?
  guest_bootstrap.guest_bootstrap_write_phase(GUEST_CONTEXT, "2")?
}

proc run_phase_one_stale(paths: trust_store.TrustStorePaths) [fs, process, time, error] {
  let active = trust_store.trust_store_read_active(paths)?
  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, f"ENTRY phase=1 active={active} journal={journal_present(paths)?}")?
  guard active == "2" else {
    return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "phase1", "expected active generation 2 on entry")
  }

  let accepted_before = trust_store.trust_store_read_accepted(paths)?
  guard accepted_before == "2" else {
    return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "phase1", "expected accepted generation 2 on entry")
  }

  trust_store.trust_store_write_journal(paths, "committed", "1", "staging/stale-gone", "stale")?
  let journal_before = paths.journal.read_bytes()?

  match trust_update.trust_update_from_dir(p"/", p"/releases/release-c") {
    Ok(_) => {
      return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "phase1", "stale generation-1 journal was recovered over accepted generation 2")
    },
    Err(problem) => {
      guard "behind accepted generation" in problem.message else {
        return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "phase1", f"stale journal failed with the wrong error: {problem.message}")
      }
    },
  }

  guard trust_store.trust_store_read_active(paths)? == "2" else {
    return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "phase1", "active generation moved during stale journal recovery")
  }

  guard trust_store.trust_store_read_accepted(paths)? == accepted_before else {
    return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "phase1", "accepted generation moved during stale journal recovery")
  }

  guard paths.journal.read_bytes()? == journal_before else {
    return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "phase1", "stale journal was mutated during refused recovery")
  }

  let status = trust_update.trust_status(p"/")?
  guard status.generation.require(Str)? == "2" and status.accepted.require(Str)? == "2" else {
    return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "phase1", "status is not a clean generation 2 after refused recovery")
  }

  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, f"STALE_OK generation=2 bundle={status.bundle_sha256.require(Str)?} policy={status.policy_sha256.require(Str)?}")?
  guest_bootstrap.guest_bootstrap_write_phase(GUEST_CONTEXT, "2")?
}

proc run_phase_two(paths: trust_store.TrustStorePaths) [fs, time, error] {
  let active = trust_store.trust_store_read_active(paths)?
  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, f"ENTRY phase=2 active={active} journal={journal_present(paths)?}")?
  guard active == "3" else {
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "FAIL phase2 expected active generation 3 on replay")?
    return Err(guest_bootstrap.GuestTrustError.Failed(phase: "phase2", message: "expected active generation 3 on replay"))
  }

  let status = trust_update.trust_status(p"/")?
  guard status.accepted.require(Str)? == "3" and status.pending.require(Str)? == "none" else {
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "FAIL phase2 replayed status is not a clean generation 3")?
    return Err(guest_bootstrap.GuestTrustError.Failed(phase: "phase2", message: "replayed status is not clean"))
  }

  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, f"REPLAY_OK generation=3 bundle={status.bundle_sha256.require(Str)?} policy={status.policy_sha256.require(Str)?}")?
}

proc main() [fs, process, time, net, error, io] {
  p"/proc".mkdir(parents: true)
  p"/sys".mkdir(parents: true)
  match linux.mount(bytes.from_text("devtmpfs"), p"/dev", fstype: "devtmpfs") {
    Ok(_) => {},
    Err(problem) => return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "boot", f"mount devtmpfs: {problem.message}"),
  }

  match linux.mount(bytes.from_text("proc"), p"/proc", fstype: "proc") {
    Ok(_) => {},
    Err(problem) => return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "boot", f"mount proc: {problem.message}"),
  }

  match linux.mount(bytes.from_text("sysfs"), p"/sys", fstype: "sysfs") {
    Ok(_) => {},
    Err(problem) => return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "boot", f"mount sysfs: {problem.message}"),
  }

  guest_bootstrap.guest_bootstrap_load_drivers(GUEST_CONTEXT, "boot")?
  guest_bootstrap.guest_bootstrap_mount_store(GUEST_CONTEXT, "boot")?
  fp"/store/trust".mkdir(parents: true)
  guest_bootstrap.guest_bootstrap_bring_up_net(GUEST_CONTEXT, "boot")?

  let url = guest_bootstrap.guest_bootstrap_cmdline_value(GUEST_CONTEXT, "trust_url")?
  let mode = guest_bootstrap.guest_bootstrap_cmdline_value(GUEST_CONTEXT, "trust_mode")?
  let paths = trust_store.trust_store_paths(p"/")
  let phase = guest_bootstrap.guest_bootstrap_read_phase(GUEST_CONTEXT)?
  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, f"BOOT phase={phase} mode={mode}")?

  if phase == "0" {
    run_phase_zero(paths)?
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "REBOOTING")?
    linux.reboot()?
    return
  }

  if phase == "1" {
    if mode == "stale" {
      run_phase_one_stale(paths)?
      guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "POWEROFF")?
      linux.poweroff()?
      return
    }

    run_phase_one(paths, url, mode)?
    if mode == "replay" {
      guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "REBOOTING")?
      linux.reboot()?
      return
    }

    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "POWEROFF")?
    linux.poweroff()?
    return
  }

  guard phase == "2" else {
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "FAIL boot refusing an unknown trust phase")?
    return Err(guest_bootstrap.GuestTrustError.Failed(phase: "boot", message: "unknown trust phase"))
  }

  run_phase_two(paths)?
  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "POWEROFF")?
  linux.poweroff()?
}

main()?
