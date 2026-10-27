#!/bin/xsh --
use pm.generation
error ReplayGuestError = Failed

proc require_disposable_guest() {
  assert "LAPUTA_SELF_HOSTING=1" in p"/proc/cmdline".read_text()?.trim().split(" ")
  assert generation.read_generation_receipt(p"/")?.profile.name == "qemu-self-hosting"
}

proc present(pid: Int) -> Result[Bool] {
  for entry in process.list()? {
    return true when entry.pid == pid
  }
  false
}

proc wait_file(marker: Path) {
  let deadline = time.monotonic()? + 8000000000
  while time.monotonic()? < deadline {
    return when marker.exists()
    time.sleep(20ms)
  }
  Err(ReplayGuestError.Failed(f"deadline waiting for {marker}"))
}

proc descendant(root: Path) {
  unix.signal_setup(["TERM", "INT"])
  fp"{root}/descendant-ready".write_atomic(f"{process.current_pid()?}")
  while unix.take_signals()?.is_empty() {
    time.sleep(20ms)
  }
}

proc leader(root: Path) {
  let fixture = p"/mnt/self-hosting/inputs/laputa/xinit/tests/fixtures/lifecycle_replay_guest.xsh"
  if fp"{root}/original-child".exists() {
    let old = fp"{root}/original-child".read_text()?.parse_int()?
    if present(old) {
      fp"{root}/violation".write_atomic("surviving-owned-descendant")
      return
    }
    assert fp"{root}/finished".exists()?, "replacement preceded finish"
    fp"{root}/replacement".write_atomic(f"{process.current_pid()?}")
  }
  let child = process.spawn(process.command_argv("/usr/bin/xsh", ["xsh", fixture.display(), "--", "descendant", root.display()], same_group: true))?
  assert process.group_id(child.pid)? == process.group_id()?
  if ! fp"{root}/original-child".exists() {
    fp"{root}/original-child".write_atomic(f"{child.pid}")
    fp"{root}/original-leader".write_atomic(f"{process.current_pid()?}")
  }
  while true {
    time.sleep(100ms)
  }
}

proc finish(root: Path) {
  let child = fp"{root}/original-child".read_text()?.parse_int()?
  if present(child) {
    fp"{root}/violation".write_atomic("surviving-owned-descendant")
  } else {
    fp"{root}/finished".write_atomic("1")
  }
}

proc exercise(root: Path, wrong: Bool) {
  assert ! root.exists()?
  root.mkdir()
  fp"{root}/services".mkdir()
  let fixture = p"/mnt/self-hosting/inputs/laputa/xinit/tests/fixtures/lifecycle_replay_guest.xsh"
  let canonical = p"/mnt/self-hosting/inputs/laputa/xinit/xinit.xsh"
  var source = canonical
  if wrong {
    let text = canonical.read_text()?
    let correct = "unix.shutdown_process_groups([unit.pid], time.millis(unit.service.stop_timeout_ms), 100ms)?"
    let broken = "unix.shutdown_process_groups([], time.millis(unit.service.stop_timeout_ms), 100ms)?"
    assert text.split(correct).len() == 2, "wrong-repair mutation must match exactly once"
    source = fp"{root}/wrong-xinit.xsh"
    source.write(text.replace(correct, with: broken))
  }
  let argv = json.encode(["xsh", fixture.display(), "--", "leader", root.display()])?
  fp"{root}/services/replay.xsh".write(f"""##! An owned leader and descendant for disposable VM replay.

## The scanner owns the complete service process group.
export let service = {{
  name: "replay",
  command: process.command_argv("/usr/bin/xsh", {argv}),
  stop_timeout_ms: 200,
  restart: {{mode: "always", delay_ms: 200, max_delay_ms: 200, stable_after_ms: 100000}},
  logging: "append",
}}
## Observes the original descendant after the scanner reaps its owned group.
export proc finish() [fs, process, env, error] -> Result[Unit, Error] {{
  run /usr/bin/xsh "{fixture}" -- finish "{root}"
}}
""")
  let scanner = unix.spawn_process_group_log(process.command_argv("/usr/bin/xsh", ["xsh", source.display(), "--", "supervise", "replay"], env: {
    XSH_ROOT: "/usr/lib/xsh",
    XINIT_SERVICE_DIR: fp"{root}/services".display(),
    XINIT_RUN_DIR: fp"{root}/run".display(),
    XINIT_LOG_ROOT: fp"{root}/logs".display(),
    XINIT_TEST_ALLOW_NON_PID1: "0",
  }), fp"{root}/scanner.log")?
  var groups = [scanner.pid]
  defer {
    let cleanup = unix.shutdown_process_groups(groups, 2s, 100ms)?
    assert cleanup.remaining.is_empty(), "VM replay retained owned groups"
    for diagnostic in [fp"{root}/scanner.log", fp"{root}/services/replay.xsh", fp"{root}/run/replay.json", fp"{root}/logs/replay/current"] {
      if diagnostic.exists() {
        print f"LAP34_DIAGNOSTIC {diagnostic}"
        print diagnostic.read_text()?
      }
    }
  }
  wait_file(fp"{root}/original-leader")
  let first = fp"{root}/original-leader".read_text()?.parse_int()?
  groups += [first]
  wait_file(fp"{root}/descendant-ready")
  let child = fp"{root}/original-child".read_text()?.parse_int()?
  assert fp"{root}/descendant-ready".read_text()?.parse_int()? == child
  assert process.group_id(first)? == first and process.group_id(child)? == first
  process.kill(first, signal: "KILL")
  if wrong {
    wait_file(fp"{root}/violation")
    assert fp"{root}/violation".read_text()? == "surviving-owned-descendant"
    assert present(child)?, "negative replay lost its counterexample"
    assert process.group_id(child)? == first
    print "LAP34_VM_NEGATIVE invariant=surviving-owned-descendant prefix=crash"
  } else {
    wait_file(fp"{root}/replacement")
    let replacement = fp"{root}/replacement".read_text()?.parse_int()?
    groups += [replacement]
    assert replacement != first and process.group_id(replacement)? == replacement
    assert ! present(child)? and ! present(first)?, "canonical replay retained crashed group"
    assert fp"{root}/finished".exists()? and ! fp"{root}/violation".exists()?
    print "LAP34_VM_CANONICAL cleanup-before-finish-and-respawn=true prefix=crash"
  }
}

proc main(...argv: List[Str]) {
  require_disposable_guest()
  if argv.len() == 2 {
    let root = fp"{argv[1]}"
    if argv[0] == "descendant" {
      descendant(root)
    } else if argv[0] == "leader" {
      leader(root)
    } else {
      assert argv[0] == "finish"
      finish(root)
    }
  } else {
    assert argv.is_empty()
    unix.pid1_setup(["TERM", "INT"], subreaper: true, allow_non_pid1: true)
    let root = fp"/run/xinit-replay-{process.current_pid()?}"
    exercise(fp"{root}-canonical", false)
    exercise(fp"{root}-wrong", true)
    print "LAP34_VM_OK"
  }
}
