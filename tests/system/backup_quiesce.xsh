##! Backup quiescence: records, ownership tokens, and recovery, against an xinit stand-in.
use system.backup_quiesce as quiesce

const STUB = """##! xinit stand-in that applies each request at once.

proc put(path_value: Path, text: Str) [fs, error] {
  path_value.write(text)?
}

proc note(state: Path, line: Str) [fs, error] {
  note_to(state, "stub.log", line)?
}

proc note_to(state: Path, name: Str, line: Str) [fs, error] {
  let log = fp"{state}/{name}"
  let before = if log.exists()? { log.read_text()? } else { "" }
  log.write(before + line + "\\n")?
}

proc status(state: Path, service: Str, desired: Str, health: Str) [fs, error] {
  put(fp"{state}/{service}.json", json.encode({name: service, desired: desired, state: health})?)?
}

proc main(...argv: List[Str]) [fs, process, error] {
  let state = fp"{argv[0]}"
  let verb = argv[1]
  var owner = ""
  var if_owner = ""
  var service = ""
  var index = 2
  while index < argv.len() {
    if argv[index] == "--owner" {
      owner = argv[index + 1]
      index += 2
    } else if argv[index] == "--if-owner" {
      if_owner = argv[index + 1]
      index += 2
    } else {
      service = argv[index]
      index += 1
    }
  }
  note_to(state, "requests.log", argv.join(" "))?
  let control = fp"{state}/{service}.control"
  let current = if control.exists()? { control.read_text()?.trim() } else { "" }
  if verb == "stop" {
    if fp"{state}/fail-stop-{service}".exists()? {
      eprint "stub: stop refused"
      exit 1
    }
    if owner == "" {
      control.remove(missing_ok: true)?
    } else {
      put(control, owner)?
    }
    status(state, service, "down", "stopped")?
    note(state, f"{service} down")?
  } else {
    let failing = fp"{state}/fail-start-{service}"
    if failing.exists()? {
      let left = failing.read_text()?.trim().parse_int()?
      if left > 0 {
        put(failing, f"{left - 1}")?
        eprint "stub: start refused"
        exit 1
      }
    }
    if if_owner != "" and (fp"{state}/inbox/{service}".exists()? or current != if_owner) {
      if current == if_owner {
        exit 1
      }
      note(state, f"{service} skipped")?
      return
    }
    control.remove(missing_ok: true)?
    status(state, service, "up", "running")?
    note(state, f"{service} up")?
  }
}
"""

type Rig = {env: quiesce.QuiesceEnv, root: Path}

proc rig(ctx: TestContext, name: Str, services: Record) [fs, process, env, error] -> Result[Rig, Error] {
  let root = test.temp_dir(ctx, name: name)?
  let state = fp"{root}/state"
  state.mkdir()
  fp"{root}/stub.xsh".write(STUB)
  for service in services.keys() {
    let desired = services.get(service)?.require(Str)?
    fp"{state}/{service}.json".write(json.encode({name: service, desired: desired, state: if desired == "up" { "running" } else { "stopped" }})?)
  }
  let host = e"XSH_HOST" ?? "xsh"
  Ok({
    env: {
      xinit: [host, f"{root}/stub.xsh", f"{state}"],
      state_dir: state,
      records: fp"{root}/records",
      writers: fp"{root}/writers",
      scratch: fp"{root}/scratch",
    },
    root: root,
  })
}

proc options_of(argv: List[Str]) -> Result[quiesce.QuiesceOptions, Error] {
  match quiesce.quiesce_options(argv) {
    Ok(parsed) => Ok(parsed)
    Err(problem) => Err(error.failure(problem))
  }
}

proc options(services: List[Str]) -> Result[quiesce.QuiesceOptions, Error] {
  match quiesce.quiesce_options(["stop", @services, "--timeout-ms", "2000", "--recover-timeout-ms", "1500"]) {
    Ok(parsed) => Ok(parsed)
    Err(problem) => Err(error.failure(problem))
  }
}

proc transitions(rig: Rig) [fs, error] -> Result[List[Str], Error] {
  let log = fp"{rig.env.state_dir}/stub.log"
  if ! log.exists()? {
    return Ok([])
  }
  Ok(log.read_text()?.lines() |> where .trim() != "" |> collect)
}

proc plan(rig: Rig, services: List[Str]) [fs, error] -> Result[quiesce.QuiesceRecord, Error] {
  quiesce.quiesce_plan(rig.env, "backup", 1, services, "boot-1", 1767225600000, options(services)?)
}

proc status_of(rig: Rig, service: Str) [fs, error] -> Result[Str, Error] {
  let value = json.read(fp"{rig.env.state_dir}/{service}.json")?
  Ok(json.get(value, ["desired"], "").require(Str)?)
}

test test_release_step_never_restores_a_stop_it_does_not_own [error] {
  assert quiesce.quiesce_release_step("q1a1", "q1a1", false) == "request"
  assert quiesce.quiesce_release_step("q1a1", "", false) == "done"
  assert quiesce.quiesce_release_step("q1a1", "q2a1", false) == "done"
  assert quiesce.quiesce_release_step("q1a1", "q1a1", true) == "wait"
  assert quiesce.quiesce_release_step("q1a1", "", true) == "wait"
  assert quiesce.quiesce_token(1767225600000, 2) == "q1767225600000a2"
}

test test_hook_options_publish_the_recovery_bound [error] {
  let defaults = options_of(["stop", "logger"])?
  assert defaults.timeout_ms == quiesce.QUIESCE_DEFAULT_TIMEOUT_MS
  assert defaults.release_timeout_ms == quiesce.QUIESCE_DEFAULT_RELEASE_TIMEOUT_MS
  assert defaults.retry_delay_ms == quiesce.QUIESCE_DEFAULT_RETRY_DELAY_MS
  assert defaults.max_attempts == quiesce.QUIESCE_DEFAULT_MAX_ATTEMPTS
  let tuned = options_of(["stop", "logger", "--recover-timeout-ms", "5", "--recover-retry-ms", "6", "--recover-attempts", "7"])?
  assert tuned.release_timeout_ms == 5 and tuned.retry_delay_ms == 6 and tuned.max_attempts == 7
  assert quiesce.quiesce_options(["stop", "logger", "--recover-attempts", "0"]) is Err(_)
  assert quiesce.quiesce_options(["reconcile", "a", "b"]) is Err(_)
  assert quiesce.quiesce_options(["reconcile"]) is Err(_)
  assert quiesce.quiesce_options(["frob", "a"]) is Err(_)
}

test test_record_refuses_foreign_input [error] {
  let good = {format: quiesce.QUIESCE_RECORD_FORMAT, job: "backup", token: "q1a1", services: [{name: "logger", prior_desired: "up", acquired: true}]}
  assert quiesce.quiesce_record_from_json(good)?.services.len() == 1
  assert quiesce.quiesce_record_from_json({format: "x", job: "backup", token: "q1a1"}) is Err(_)
  assert quiesce.quiesce_record_from_json({format: quiesce.QUIESCE_RECORD_FORMAT, job: "../x", token: "q1a1"}) is Err(_)
  assert quiesce.quiesce_record_from_json({format: quiesce.QUIESCE_RECORD_FORMAT, job: "backup", token: "bad token"}) is Err(_)
  assert quiesce.quiesce_record_from_json({format: quiesce.QUIESCE_RECORD_FORMAT, job: "backup", token: "q1a1", services: [{name: "a/b"}]}) is Err(_)
}

test test_a_service_that_was_stopped_stays_stopped [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-prior-down", {logger: "up", "dhcp-eth0": "down"})?
  let record = plan(r, ["logger", "dhcp-eth0"])?
  assert record.services[0].acquired and ! record.services[1].acquired
  quiesce.quiesce_write_record(r.env, record)?
  quiesce.quiesce_stop_service(r.env, record, "logger")?
  assert transitions(r)? == ["logger down"]
  assert quiesce.quiesce_release_record(r.env, "backup", 0)?
  assert transitions(r)? == ["logger down", "logger up"]
  assert status_of(r, "logger")? == "up"
  assert status_of(r, "dhcp-eth0")? == "down"
  assert quiesce.quiesce_read_record(r.env, "backup")? == null
}

test test_every_stop_and_release_request_carries_the_attempts_token [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-tokens", {logger: "up"})?
  let record = plan(r, ["logger"])?
  quiesce.quiesce_write_record(r.env, record)?
  quiesce.quiesce_stop_service(r.env, record, "logger")?
  assert quiesce.quiesce_release_record(r.env, "backup", 0)?
  let requests = fp"{r.env.state_dir}/requests.log".read_text()?.lines() |> where .trim() != "" |> collect
  assert requests.len() == 2
  assert requests[0].ends_with(f"stop --owner {record.token} logger"), requests[0]
  assert requests[1].ends_with(f"start --if-owner {record.token} logger"), requests[1]
}

test test_partial_quiesce_restores_only_what_was_stopped [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-partial", {logger: "up", "dhcp-eth0": "up"})?
  let record = plan(r, ["logger", "dhcp-eth0"])?
  quiesce.quiesce_write_record(r.env, record)?
  quiesce.quiesce_stop_service(r.env, record, "logger")?
  fp"{r.env.state_dir}/fail-stop-dhcp-eth0".write("x")
  assert quiesce.quiesce_stop_service(r.env, record, "dhcp-eth0") is Err(_)
  assert quiesce.quiesce_release_record(r.env, "backup", 0)?
  assert transitions(r)? == ["logger down", "logger up"]
  assert status_of(r, "dhcp-eth0")? == "up"
  assert quiesce.quiesce_read_record(r.env, "backup")? == null
}

test test_interruption_between_durable_steps_never_strands_or_double_starts [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)

  # After the record is durable and before any stop: nothing was taken, so nothing is started.
  let early = rig(ctx, "quiesce-cut-record", {logger: "up", "dhcp-eth0": "up"})?
  quiesce.quiesce_write_record(early.env, plan(early, ["logger", "dhcp-eth0"])?)?
  assert quiesce.quiesce_release_record(early.env, "backup", 0)?
  assert transitions(early)? == []
  assert quiesce.quiesce_read_record(early.env, "backup")? == null

  # After every stop and before the release: both come back, once each.
  let late = rig(ctx, "quiesce-cut-stops", {logger: "up", "dhcp-eth0": "up"})?
  let record = plan(late, ["logger", "dhcp-eth0"])?
  quiesce.quiesce_write_record(late.env, record)?
  quiesce.quiesce_stop_service(late.env, record, "logger")?
  quiesce.quiesce_stop_service(late.env, record, "dhcp-eth0")?
  assert quiesce.quiesce_release_record(late.env, "backup", 0)?
  assert transitions(late)? == ["logger down", "dhcp-eth0 down", "logger up", "dhcp-eth0 up"]

  # After the first service was handed back and before the second: only the second is started.
  let middle = rig(ctx, "quiesce-cut-release", {logger: "up", "dhcp-eth0": "up"})?
  let held = plan(middle, ["logger", "dhcp-eth0"])?
  quiesce.quiesce_write_record(middle.env, held)?
  quiesce.quiesce_stop_service(middle.env, held, "logger")?
  quiesce.quiesce_stop_service(middle.env, held, "dhcp-eth0")?
  quiesce.quiesce_release_service(middle.env, held, "logger", 1500)?
  assert quiesce.quiesce_release_record(middle.env, "backup", 0)?
  assert transitions(middle)? == ["logger down", "dhcp-eth0 down", "logger up", "dhcp-eth0 up"]

  # After the last release and before the record was retired: a repeat costs no transition.
  let final = rig(ctx, "quiesce-cut-retire", {logger: "up"})?
  let last = plan(final, ["logger"])?
  quiesce.quiesce_write_record(final.env, last)?
  quiesce.quiesce_stop_service(final.env, last, "logger")?
  quiesce.quiesce_release_service(final.env, last, "logger", 1500)?
  let before = transitions(final)?
  assert quiesce.quiesce_release_record(final.env, "backup", 0)?
  assert transitions(final)? == before
}

test test_an_operator_stop_after_acquisition_survives_recovery [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-operator-stop", {logger: "up", "dhcp-eth0": "up"})?
  let record = plan(r, ["logger", "dhcp-eth0"])?
  quiesce.quiesce_write_record(r.env, record)?
  quiesce.quiesce_stop_service(r.env, record, "logger")?
  quiesce.quiesce_stop_service(r.env, record, "dhcp-eth0")?
  let operator = process.run(process.command_argv(r.env.xinit[0], r.env.xinit + ["stop", "logger"]))?
  assert operator.ok
  assert quiesce.quiesce_release_record(r.env, "backup", 0)?
  assert transitions(r)? == ["logger down", "dhcp-eth0 down", "logger down", "dhcp-eth0 up"]
  assert status_of(r, "logger")? == "down"
  assert status_of(r, "dhcp-eth0")? == "up"
}

test test_an_operator_start_after_acquisition_is_not_restarted [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-operator-start", {logger: "up"})?
  let record = plan(r, ["logger"])?
  quiesce.quiesce_write_record(r.env, record)?
  quiesce.quiesce_stop_service(r.env, record, "logger")?
  assert process.run(process.command_argv(r.env.xinit[0], r.env.xinit + ["start", "logger"]))?.ok
  assert quiesce.quiesce_release_record(r.env, "backup", 0)?
  assert transitions(r)? == ["logger down", "logger up"]
}

test test_a_failed_release_keeps_the_record_and_a_retry_completes [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-release-retry", {logger: "up", "dhcp-eth0": "up"})?
  let record = plan(r, ["logger", "dhcp-eth0"])?
  quiesce.quiesce_write_record(r.env, record)?
  quiesce.quiesce_stop_service(r.env, record, "logger")?
  quiesce.quiesce_stop_service(r.env, record, "dhcp-eth0")?
  fp"{r.env.state_dir}/fail-start-logger".write("1000")

  assert quiesce.quiesce_release_record(r.env, "backup", 400) is Err(_)
  assert quiesce.quiesce_read_record(r.env, "backup")? != null
  assert status_of(r, "logger")? == "down"
  assert status_of(r, "dhcp-eth0")? == "up"

  fp"{r.env.state_dir}/fail-start-logger".write("0")
  assert quiesce.quiesce_release_record(r.env, "backup", 0)?
  assert quiesce.quiesce_read_record(r.env, "backup")? == null
  assert status_of(r, "logger")? == "up"
  assert transitions(r)? == ["logger down", "dhcp-eth0 down", "dhcp-eth0 up", "logger up"]
  assert ! quiesce.quiesce_release_record(r.env, "backup", 0)?
  assert transitions(r)?.len() == 4
}

test test_transient_start_failures_are_retried_within_one_release [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-release-transient", {logger: "up"})?
  let record = plan(r, ["logger"])?
  quiesce.quiesce_write_record(r.env, record)?
  quiesce.quiesce_stop_service(r.env, record, "logger")?
  fp"{r.env.state_dir}/fail-start-logger".write("2")
  assert quiesce.quiesce_release_record(r.env, "backup", 0)?
  assert status_of(r, "logger")? == "up"
  assert transitions(r)? == ["logger down", "logger up"]
}

test test_recovery_waits_for_a_queued_request_before_deciding [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-queued", {logger: "up"})?
  let record = plan(r, ["logger"])?
  quiesce.quiesce_write_record(r.env, record)?
  fp"{r.env.state_dir}/inbox".mkdir()
  fp"{r.env.state_dir}/inbox/logger".write(f"down owner={record.token}")
  assert quiesce.quiesce_release_record(r.env, "backup", 300) is Err(_)
  assert quiesce.quiesce_read_record(r.env, "backup")? != null
  assert transitions(r)? == []
}

test test_only_a_supervised_attempt_may_quiesce [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-supervised", {logger: "up"})?
  let opts = options(["logger"])?
  assert quiesce.quiesce_acquire(r.env, "", 1, opts) is Err(_)
  assert quiesce.quiesce_acquire(r.env, "backup", 1, opts) is Err(_)

  r.env.writers.mkdir(parents: true)
  let session = process.session_id()?
  fp"{r.env.writers}/backup.json".write(json.encode({pid: session + 1, attempt: 1})?)
  assert quiesce.quiesce_acquire(r.env, "backup", 1, opts) is Err(_)
  fp"{r.env.writers}/backup.json".write(json.encode({pid: session, attempt: 2})?)
  assert quiesce.quiesce_acquire(r.env, "backup", 1, opts) is Err(_)
  assert transitions(r)? == []
  assert quiesce.quiesce_read_record(r.env, "backup")? == null

  fp"{r.env.writers}/backup.json".write(json.encode({pid: session, attempt: 1})?)
  quiesce.quiesce_acquire(r.env, "backup", 1, opts)?
  assert transitions(r)? == ["logger down"]
  let held = quiesce.quiesce_read_record(r.env, "backup")?
  assert held != null
  assert quiesce.quiesce_acquire(r.env, "backup", 1, opts) is Err(_)
  assert transitions(r)? == ["logger down"]
}

test test_the_record_is_durable_before_the_first_stop [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let r = rig(ctx, "quiesce-record-first", {logger: "up", "dhcp-eth0": "up"})?
  r.env.writers.mkdir(parents: true)
  fp"{r.env.writers}/backup.json".write(json.encode({pid: process.session_id()?, attempt: 1})?)
  fp"{r.env.state_dir}/fail-stop-dhcp-eth0".write("x")
  assert quiesce.quiesce_acquire(r.env, "backup", 1, options(["logger", "dhcp-eth0"])?) is Err(_)
  let held = quiesce.quiesce_read_record(r.env, "backup")?
  guard let record = held else {
    fail "the failed attempt left no record to recover from"
  }
  assert record.services.len() == 2 and record.services[0].acquired and record.services[1].acquired
  assert quiesce.quiesce_release_record(r.env, "backup", 0)?
  assert status_of(r, "logger")? == "up" and status_of(r, "dhcp-eth0")? == "up"
  assert transitions(r)? == ["logger down", "logger up"]
}
