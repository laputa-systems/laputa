use guest.bootstrap as guest_bootstrap
use pm.remote
use pm.repo_snapshot

const GUEST_CONTEXT = {marker: "LAPUTA_REPO_GUEST", phase_file: "/store/repo-phase"}

proc main() [fs, process, time, net, error, io] {
  p"/proc".mkdir(parents: true)
  p"/sys".mkdir(parents: true)
  linux.mount(bytes.from_text("devtmpfs"), p"/dev", fstype: "devtmpfs")
  linux.mount(bytes.from_text("proc"), p"/proc", fstype: "proc")
  linux.mount(bytes.from_text("sysfs"), p"/sys", fstype: "sysfs")
  guest_bootstrap.guest_bootstrap_load_drivers(GUEST_CONTEXT, "boot")
  guest_bootstrap.guest_bootstrap_mount_store(GUEST_CONTEXT, "boot")
  guest_bootstrap.guest_bootstrap_bring_up_net(GUEST_CONTEXT, "boot")
  let url = guest_bootstrap.guest_bootstrap_cmdline_value(GUEST_CONTEXT, "repo_url")?
  let keys = [p"/guest/signing-key".read_bytes()?, p"/guest/next-key".read_bytes()?]
  let state = p"/store/state"
  let phase = guest_bootstrap.guest_bootstrap_read_phase(GUEST_CONTEXT)?
  if phase == "0" {
    let index = remote.load_verified_remote_index(url, p"/store/out", keys, 1995000000, state.display())?
    guard index.len() == 1 and index[0].name == "fixture" else {
      return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "accept", "signed index had unexpected contents")
    }
    let accepted = repo_snapshot.snapshot_read_accepted(repo_snapshot.snapshot_state_paths(state, url))?
    guard accepted != null else { return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "accept", "missing accepted state") }
    guard accepted.generation == "2" else { return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "accept", "wrong accepted generation") }
    match remote.load_verified_remote_index(f"{url}/tampered", p"/store/tampered-out", keys, 1995000000, state.display()) {
      Ok(_) => return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "tamper", "tampered index was accepted"),
      Err(problem) => guard "does not match signed snapshot metadata" in problem.message else { return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "tamper", problem.message) },
    }
    guard ! p"/store/tampered-out".exists() else { return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "tamper", "tampered index was cached") }
    guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "ACCEPT_AND_TAMPER_OK generation=2")
    guest_bootstrap.guest_bootstrap_write_phase(GUEST_CONTEXT, "1")
    linux.reboot()
    return
  }
  guard phase == "1" else { return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "boot", "unknown phase") }
  match remote.load_verified_remote_index(url, p"/store/rollback-out", keys, 1995000000, state.display()) {
    Ok(_) => return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "rollback", "older snapshot was accepted after reboot"),
    Err(problem) => guard "accepted snapshot" in problem.message else { return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "rollback", problem.message) },
  }
  let accepted = repo_snapshot.snapshot_read_accepted(repo_snapshot.snapshot_state_paths(state, url))?
  guard accepted != null else { return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "rollback", "accepted state disappeared") }
  guard accepted.generation == "2" else { return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "rollback", "accepted generation changed") }
  guard ! p"/store/rollback-out".exists() else { return guest_bootstrap.guest_bootstrap_fail_phase(GUEST_CONTEXT, "rollback", "older index was cached") }
  guest_bootstrap.guest_bootstrap_say(GUEST_CONTEXT, "ROLLBACK_REJECTED generation=2")
  linux.poweroff()
}

main()
