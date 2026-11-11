#!/bin/xsh --
const RUN = p"/run/xinit"
const EVENTS = p"/run/r1/events"

type CheckResult = {code: Int, message: Str}

proc boot_ms() -> Result[Int] {
  time.boottime()? / 1000000
}

proc say(text: Str) [fs, io, error] {
  let console = p"/dev/console"
  if console.exists()? {
    console.write(text + "\n")?
  } else {
    print $text
    io.flush_stdout()?
  }
}

proc status_path(name: Str) -> Path {
  fp"{RUN}/{name}.json"
}

proc await_status(name: Str, timeout_ms: Int) -> Result[Unit] {
  let deadline = boot_ms()? + timeout_ms
  while boot_ms()? < deadline {
    if status_path(name).exists()? {
      return Ok()
    }
    time.sleep(25ms)?
  }
  Err(error.failure(f"no status written for {name}"))
}

proc await_running(name: Str, previous: Int, wanted_ready: Bool, timeout_ms: Int) -> Result[Int] {
  let deadline = boot_ms()? + timeout_ms
  while boot_ms()? < deadline {
    if status_path(name).exists()? {
      let raw = json.read(status_path(name))?
      let state = json.get(raw, ["state"], "").require(Str)?
      let pid = json.get(raw, ["pid"], 0).require(Int)?
      let ready = json.get(raw, ["ready"], false).require(Bool)?
      if state == "running" and pid > 0 and pid != previous and ready == wanted_ready {
        return pid
      }
    }
    time.sleep(25ms)?
  }
  Err(error.failure(f"{name} did not reach running pid!={previous} ready={wanted_ready}"))
}

proc status_pid(name: Str) -> Result[Int] {
  let raw = json.read(status_path(name))?
  json.get(raw, ["pid"], 0).require(Int)
}

proc status_ready(name: Str) -> Result[Bool] {
  let raw = json.read(status_path(name))?
  json.get(raw, ["ready"], false).require(Bool)
}

proc status_restarts(name: Str) -> Result[Int] {
  let raw = json.read(status_path(name))?
  json.get(raw, ["restarts"], 0).require(Int)
}

proc event_names() -> Result[List[Str]] {
  var names: List[Str] = []
  for entry in fs.children(EVENTS)? {
    names += [entry.path.name()]
  }
  names
}

proc count_events(prefix: Str) -> Result[Int] {
  var total = 0
  for leaf in event_names()? {
    if leaf.starts_with(prefix) {
      total += 1
    }
  }
  total
}

proc latest_start(name: Str) -> Result[Int] {
  var latest = 0
  let prefix = f"start.{name}."
  for leaf in event_names()? {
    if leaf.starts_with(prefix) {
      let fields = leaf.split(".")
      let value = fields[2].parse_int() ?? 0
      if value > latest {
        latest = value
      }
    }
  }
  latest
}

proc await_start_after(name: Str, after: Int, timeout_ms: Int) -> Result[Int] {
  let deadline = boot_ms()? + timeout_ms
  while boot_ms()? < deadline {
    let latest = latest_start(name)?
    if latest > after {
      return latest
    }
    time.sleep(25ms)?
  }
  Err(error.failure(f"no start for {name} after {after}"))
}

proc scanner_pid() -> Result[Int] {
  let raw = json.read(fp"{RUN}/scanner.json")?
  json.get(raw, ["pid"], 0).require(Int)
}

proc await_scanner(after: Int, timeout_ms: Int) -> Result[Int] {
  let deadline = boot_ms()? + timeout_ms
  while boot_ms()? < deadline {
    if fp"{RUN}/scanner.json".exists()? {
      let pid = scanner_pid()?
      if pid != after {
        match process.kill(pid, "0") {
          Ok(_) => return pid,
          Err(_) => {}
        }
      }
    }
    time.sleep(25ms)?
  }
  Err(error.failure(f"scanner did not change from {after}"))
}

proc worker_count(name: Str) -> Result[Int] {
  var total = 0
  for entry in process.list()? {
    if entry.status != "Z" and "worker.xsh" in entry.argv and name in entry.argv {
      total += 1
    }
  }
  total
}

proc scanner_count() -> Result[Int] {
  var total = 0
  for entry in process.list()? {
    if entry.status != "Z" and "xinit" in entry.argv and "scan" in entry.argv and "boot" in entry.argv {
      total += 1
    }
  }
  total
}

proc xinit_status(name: Str) -> Result[Str] {
  let out = fp"/run/r1/status.{name}"
  let failure = fp"/run/r1/status.{name}.err"
  let command = process.command_argv(p"/usr/bin/xinit", ["/usr/bin/xinit", "status", name], p"/", {}, b"", out, failure, timeout: 10s)
  let status = process.run(command)?
  guard status.ok else {
    return Err(error.failure(f"xinit status {name} exited {status.shell_code()?}"))
  }
  out.read_text()
}

proc check_broken() -> Result[CheckResult] {
  let out = p"/run/r1/check.out"
  let failure = p"/run/r1/check.err"
  let command = process.command_argv(p"/usr/bin/xinit", ["/usr/bin/xinit", "check", "/etc/r1/broken.xsh"], p"/", {}, b"", out, failure, timeout: 10s)
  let status = process.run(command)?
  let message = if failure.exists()? { failure.read_text()? } else { "" }
  Ok({code: status.shell_code()?, message: message})
}

proc main() [fs, process, env, time, io, error] -> Result[Unit] {
  EVENTS.mkdir(parents: true)?
  await_status("r1-base", 15000)?
  await_status("r1-app", 15000)?
  await_status("r1-slow", 15000)?

  let base_pid = await_running("r1-base", 0, true, 15000)?
  let app_pid = await_running("r1-app", 0, true, 15000)?
  let slow_pid = await_running("r1-slow", 0, false, 15000)?
  let base_starts = count_events("start.r1-base.")?
  let app_starts = count_events("start.r1-app.")?
  let slow_starts = count_events("start.r1-slow.")?
  let initial_scanners = scanner_count()?
  guard base_starts == 1 and app_starts == 1 and slow_starts == 1 else {
    return Err(error.failure(f"initial starts base={base_starts} app={app_starts} slow={slow_starts}"))
  }
  guard initial_scanners == 1 else {
    return Err(error.failure(f"scanner processes={initial_scanners}"))
  }
  say(f"R1_GRAPH {json.encode({base: base_starts, app: app_starts, slow: slow_starts, scanners: initial_scanners})?}")?
  let base_line = xinit_status("r1-base")?.trim()
  let app_line = xinit_status("r1-app")?.trim()
  let slow_line = xinit_status("r1-slow")?.trim()
  say(f"R1_STATUS {base_line}")?
  say(f"R1_STATUS {app_line}")?
  say(f"R1_STATUS {slow_line}")?

  let kill_ms = boot_ms()?
  process.kill(app_pid, "KILL")?
  var dead_seen = false
  var probes: List[Str] = []
  let dead_deadline = boot_ms()? + 5000
  while boot_ms()? < dead_deadline and ! dead_seen {
    if status_path("r1-app").exists()? {
      let raw = json.read(status_path("r1-app"))?
      let probed_state = json.get(raw, ["state"], "").require(Str)?
      let probed_pid = json.get(raw, ["pid"], 0).require(Int)?
      let sample = f"{probed_state}:{probed_pid}"
      if probes.is_empty() or probes[probes.len() - 1] != sample {
        probes += [sample]
      }
      if probed_state == "dead" {
        dead_seen = true
      }
    }
    if ! dead_seen {
      time.sleep(20ms)?
    }
  }
  let respawn_ms = await_start_after("r1-app", kill_ms, 6000)?
  let restarted_pid = await_running("r1-app", app_pid, true, 6000)?
  let observed = respawn_ms - kill_ms
  let restarts = status_restarts("r1-app")?
  guard observed >= 400 else {
    return Err(error.failure(f"respawn was not delayed: {observed} ms"))
  }
  guard restarts >= 1 else {
    return Err(error.failure("restart count did not increase"))
  }
  let app_after = count_events("start.r1-app.")?
  let base_after = count_events("start.r1-base.")?
  let slow_after = count_events("start.r1-slow.")?
  guard app_after == 2 and base_after == 1 and slow_after == 1 else {
    return Err(error.failure(f"crash cascade or missing recovery base={base_after} app={app_after} slow={slow_after}"))
  }
  say(f"R1_BACKOFF {json.encode({kill_ms: kill_ms, start_ms: respawn_ms, observed_ms: observed, restarts: restarts, dead_seen: dead_seen, scanner_pid: restarted_pid, probes: probes, starts_base: base_after, starts_app: app_after, starts_slow: slow_after})?}")?

  let old_scanner = scanner_pid()?
  let old_base = status_pid("r1-base")?
  let old_app = status_pid("r1-app")?
  let old_slow = status_pid("r1-slow")?
  process.kill(old_scanner, "TERM")?
  let new_scanner = await_scanner(old_scanner, 15000)?
  let new_base = await_running("r1-base", old_base, true, 15000)?
  let new_app = await_running("r1-app", old_app, true, 15000)?
  let new_slow = await_running("r1-slow", old_slow, false, 15000)?
  let duplicates = count_events("duplicate.")?
  let workers_base = worker_count("r1-base")?
  let workers_app = worker_count("r1-app")?
  let workers_slow = worker_count("r1-slow")?
  let scanners = scanner_count()?
  let base_restart_starts = count_events("start.r1-base.")?
  let app_restart_starts = count_events("start.r1-app.")?
  let slow_restart_starts = count_events("start.r1-slow.")?
  guard duplicates == 0 else {
    return Err(error.failure(f"duplicate instances recorded: {duplicates}"))
  }
  guard workers_base == 1 and workers_app == 1 and workers_slow == 1 else {
    return Err(error.failure(f"worker processes base={workers_base} app={workers_app} slow={workers_slow}"))
  }
  guard scanners == 1 else {
    return Err(error.failure(f"scanner processes={scanners}"))
  }
  guard base_restart_starts == 2 and app_restart_starts == 3 and slow_restart_starts == 2 else {
    return Err(error.failure(f"scanner restart duplicated starts base={base_restart_starts} app={app_restart_starts} slow={slow_restart_starts}"))
  }
  say(f"R1_SCANNER_RESTART {json.encode({old: old_scanner, new: new_scanner, base: new_base, app: new_app, slow: new_slow, duplicates: duplicates, workers_base: workers_base, workers_app: workers_app, workers_slow: workers_slow, scanners: scanners, starts_base: base_restart_starts, starts_app: app_restart_starts, starts_slow: slow_restart_starts})?}")?

  let malformed = check_broken()?
  guard malformed.code != 0 else {
    return Err(error.failure("malformed service configuration was accepted"))
  }
  guard "typo" in malformed.message else {
    return Err(error.failure(f"malformed configuration did not name the field: {malformed.message}"))
  }
  guard "/etc/r1/broken.xsh" in malformed.message else {
    return Err(error.failure(f"malformed configuration did not name the source: {malformed.message}"))
  }
  say(f"R1_MALFORMED {json.encode({status: malformed.code, field: "typo", source: "/etc/r1/broken.xsh"})?}")?

  let slow_ready = status_ready("r1-slow")?
  let readiness_line = xinit_status("r1-slow")?.trim()
  guard ! slow_ready else {
    return Err(error.failure("a readiness timeout was reported as ready"))
  }
  guard "ready=false" in readiness_line else {
    return Err(error.failure(f"readiness timeout is not explicit: {readiness_line}"))
  }
  say(f"R1_READINESS {json.encode({state: "running", ready: slow_ready})?}")?
  say(f"R1_READINESS_STATUS {readiness_line}")?

  say("R1_PROOF_READY")?
  process.kill(1, "TERM")?
  while true {
    time.sleep(1s)?
  }

  Ok()
}

match main() {
  Ok(_) => {}
  Err(failure) => {
    let console = p"/dev/console"
    if console.exists()? {
      console.write(f"R1_FAIL {failure.message}\n")?
    } else {
      print f"R1_FAIL {failure.message}"
      io.flush_stdout()?
    }
    let _ = process.kill(1, "TERM")
  }
}
