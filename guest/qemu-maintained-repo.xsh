#!/bin/xsh

##! Installed-guest signed repository fetch drill. A host harness selects it with
##! the kernel command line token LAPUTA_REPO_DRILL; without the token the script
##! exits silently like the proof script does. The key set comes from the
##! first-boot document and the accepted state lives on the maintained state disk.
use pm.remote
use pm.repo_snapshot

const KEY_FILE = p"/etc/laputa/repo-snapshot-keys"
const STATE_DIR = "/var/lib/laputa/repo-state"

proc say(message: Str) -> Result[Unit] {
  p"/dev/console".write(f"LAPUTA_REPO_INSTALLED_STEP {message}\n")
}

proc cmdline_value(name: Str) -> Result[Str] {
  for token in p"/proc/cmdline".read_text()?.words() {
    if token.starts_with(f"{name}=") {
      return token.split("=", 1)[1]
    }
  }
  fail f"{name} is missing from the kernel command line"
}

proc accepted_generation(url: Str) -> Result[Str] {
  let accepted = repo_snapshot.snapshot_read_accepted(repo_snapshot.snapshot_state_paths(Path(STATE_DIR), url))?
  if accepted == null { "none" } else { accepted.generation }
}

proc wait_for_lease() {
  let lease = p"/run/dhcpc/eth0.status"
  wait until lease.exists()? within 90s every 200ms
  var waited = 0
  while waited < 90 {
    if json.get(json.read(lease)?, ["state"], "").require(Str)? == "bound" {
      return
    }
    time.sleep(1s)?
    waited += 1
  }
  fail "dhcp lease never bound"
}

proc run_drill() {
  return unless "LAPUTA_REPO_DRILL=" in p"/proc/cmdline".read_text()?

  say("start")?
  let expect = cmdline_value("LAPUTA_REPO_DRILL")?
  let url = cmdline_value("LAPUTA_REPO_URL")?
  guard KEY_FILE.metadata()?.mode % 4096 == 0o444 else { fail "provisioned key file is not mode 0444" }
  let keys = repo_snapshot.snapshot_load_keys(KEY_FILE)?
  say("keys loaded")?
  wait_for_lease()
  say("lease bound")?
  let before = accepted_generation(url)?
  let now = time.now() / 1000
  let outcome = remote.load_verified_remote_index(url, p"/run/repo-out", keys, now, STATE_DIR)
  let after = accepted_generation(url)?
  if expect.starts_with("accept-") {
    let want = expect.split("-")[1]
    match outcome {
      Ok(items) => {
        guard items.len() == 1 else { fail "signed index had unexpected contents" }
      }
      Err(problem) => fail f"signed fetch failed: {problem.message}"
    }
    guard after == want else { fail f"accepted generation {after}, wanted {want}" }
  } else {
    let fragment = if expect == "reject-tamper" { "does not match signed snapshot metadata" } else { "accepted snapshot" }
    match outcome {
      Ok(_) => fail f"{expect}: the repository was accepted"
      Err(problem) => {
        guard fragment in problem.message else { fail f"{expect}: unexpected failure {problem.message}" }
      }
    }
    guard after == before else { fail f"{expect}: accepted generation moved from {before} to {after}" }
  }
  p"/dev/console".write(f"LAPUTA_REPO_INSTALLED_OK {expect} generation={after}\n")
  process.kill(1, signal: "TERM")?
}

proc main() -> Result[Unit, Error] {
  match run_drill() {
    Ok(_) => {}
    Err(problem) => {
      p"/dev/console".write(f"LAPUTA_REPO_INSTALLED_FAILED {problem.message}\n")
      return Err(problem)
    }
  }
}

main()?
