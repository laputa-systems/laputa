##! Remote command matrix.

use xinfra.host as host
use xinfra.model as model
use xinfra.notify as notify
use xinfra.plan as plan
use xinfra.resources.command as command
use xinfra.transport as transport

type Fixture = {
  host: Str,
  port: Int,
  username: Str,
  key: Path,
  host_key: Str,
}

proc required(name: Str) [env, error] -> Result[Str, Str] {
  match env.get(name) {
    Ok(value) => Ok(value),
    Err(error) => Err(f"missing {name}: {error.message}"),
  }
}

proc fixture(suffix: Str) [env, error] -> Result[Fixture, Str] {
  let host = required(f"XINFRA_FIXTURE_{suffix}_HOST")?
  let port_text = required(f"XINFRA_FIXTURE_{suffix}_PORT")?
  let port = match port_text.parse_int() {
    Ok(value) => value,
    Err(error) => { return Err(error.message) },
  }
  let username = required("XINFRA_FIXTURE_USER")?
  let key_text = required("XINFRA_FIXTURE_KEY")?
  let host_key = required(f"XINFRA_FIXTURE_{suffix}_HOST_KEY")?
  Ok({host: host, port: port, username: username, key: fp"{key_text}", host_key: host_key})
}

proc require(condition: Bool, message: Str) -> Result[Unit, Str] {
  if condition {
    Ok()
  } else {
    Err(message)
  }
}

proc connect(fixture: Fixture) [error] -> Result[transport.Session, Str] {
  transport.connect_endpoint(
    fixture.host,
    fixture.port,
    fixture.username,
    fixture.key,
    fixture.host_key,
  )
}

proc execute(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Str] {
  transport.exec(session, argv)
}

proc apply(session: transport.Session, host_name: Str, spec: model.CommandSpec, run_guards: Bool) -> Result[host.ApplyResult, Str] {
  match command.apply_remote(session, host_name, spec, [], run_guards) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

proc observe(session: transport.Session, spec: model.CommandSpec, run_guards: Bool) -> Result[plan.Observed, Str] {
  match command.observe(session, spec, run_guards) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

proc text_file(session: transport.Session, target: Path) -> Result[Str, Str] {
  let result = execute(session, ["cat", target.display()])?
  Ok(result.stdout.utf8() ?? "")
}

pure status_name(status: host.ApplyStatus) -> Str {
  if status == host.Changed { return "changed" }
  if status == host.Unchanged { return "unchanged" }
  if status == host.Failed { return "failed" }
  if status == host.Partial { return "partial" }
  if status == host.Blocked { return "blocked" }
  if status == host.Unknown { return "unknown" }
  "other"
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the command matrix.
export proc check_commands() [fs, process, env, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?
  let base = p"/home/xinfra/xinfra-r5-commands"

  with session = connect(a)? {
    let _ = execute(session, ["rm", "-rf", base.display()])?
    let _ = execute(session, ["mkdir", "-p", base.display()])?

    let argv_path = fp"{base}/argv"
    let argv_spec = model.CommandSpec(
      id: "argv",
      argv: ["sh", "-c", f"printf argv > {argv_path.display()}"],
    )
    let first = apply(session, a.host, argv_spec, true)?
    require(first.status == host.Changed and first.verified, "argv command did not run")?
    require(text_file(session, argv_path)? == "argv", "argv command output was wrong")?
    let second = apply(session, a.host, argv_spec, true)?
    require(second.status == host.Changed, "unconditional command did not run twice")?
    print test_case("explicit argv")

    let shell_path = fp"{base}/shell"
    let shell_spec = model.CommandSpec(id: "shell", shell: f"printf shell > {shell_path.display()}")
    let shell_result = apply(session, a.host, shell_spec, true)?
    require(shell_result.status == host.Changed, "shell command did not run")?
    require(text_file(session, shell_path)? == "shell", "shell command output was wrong")?
    print test_case("shell mode")

    let creates = fp"{base}/created"
    let _ = execute(session, ["sh", "-c", f"printf keep > {creates.display()}"])?
    let guarded = model.CommandSpec(
      id: "guarded",
      argv: ["sh", "-c", f"printf overwritten > {creates.display()}"],
      creates: creates,
    )
    let skipped = apply(session, a.host, guarded, true)?
    require(skipped.status == host.Unchanged, "creates guard did not skip")?
    require(text_file(session, creates)? == "keep", "creates guard ran the command")?
    print test_case("creates guard")

    let unless_path = fp"{base}/unless"
    let allowed = model.CommandSpec(
      id: "unless",
      argv: ["sh", "-c", f"printf ran > {unless_path.display()}"],
      unless_argv: ["sh", "-c", "exit 1"],
    )
    let allowed_result = apply(session, a.host, allowed, true)?
    require(allowed_result.status == host.Changed, "unless guard blocked a failing guard")?
    let denied = model.CommandSpec(
      id: "unless",
      argv: ["sh", "-c", f"printf again > {unless_path.display()}"],
      unless_argv: ["sh", "-c", "exit 0"],
    )
    let denied_result = apply(session, a.host, denied, true)?
    require(denied_result.status == host.Unchanged, "unless guard did not skip")?
    print test_case("unless guard")

    let counter = fp"{base}/counter"
    let always = model.CommandSpec(
      id: "always",
      argv: ["sh", "-c", f"printf x >> {counter.display()}"],
      always_run: true,
    )
    let _ = apply(session, a.host, always, true)?
    let _ = apply(session, a.host, always, true)?
    require(text_file(session, counter)? == "xx", "always_run did not run every time")?
    print test_case("always_run")

    let guard_marker = fp"{base}/guard-ran"
    let guard_spec = model.CommandSpec(
      id: "guard",
      argv: ["true"],
      unless_argv: ["sh", "-c", f"printf ran > {guard_marker.display()}; exit 0"],
    )
    let plan_before = observe(session, guard_spec, false)?
    let assessment = plan.assess(model.CommandResource(guard_spec), null, plan_before)
    require(assessment.prediction == plan.Undetermined, "plan did not refuse an unrun guard")?
    let guard_file = execute(session, ["test", "-e", guard_marker.display()])?
    require(guard_file.exit_code != 0, "plan executed the unless guard")?
    print test_case("plan refuses to run guards")

    let slow = model.CommandSpec(id: "slow", argv: ["sleep", "5"], timeout: 200ms)
    let timed = apply(session, a.host, slow, true)?
    require(timed.status == host.Unknown, "timed command did not report unknown")?
    require("after submission" in (timed.cause ?? ""), "timeout lost its certainty")?
    print test_case("command timeout is unknown")

    let file_spec = model.FileSpec(id: "notify-file", path: fp"{base}/notify", notify: ["xinfra-r5"])
    let resources = [model.File(file_spec)]
    let notified = notify.coalesce(["notify-file"], resources)
    require(notified.len() == 1 and notified[0] == "xinfra-r5", "notification was not coalesced")?
    print test_case("coalesced notification")

    let _ = execute(session, ["rm", "-rf", base.display()])?
  }

  Ok()
}
