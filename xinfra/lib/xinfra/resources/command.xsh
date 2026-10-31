##! Remote command apply logic with guards.

use xinfra.host as host
use xinfra.model as model
use xinfra.plan as plan
use xinfra.remote as remote
use xinfra.secret as secret
use xinfra.transport as transport

proc execute(session: transport.Session, argv: List[Str], timeout_ms: Int? = null, elevate: List[Str] = []) -> Result[transport.ExecResult, Error] {
  match transport.exec(session, elevate + argv, timeout_ms) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
  }
}

proc text(value: Bytes) -> Str {
  value.utf8() ?? ""
}

pure result(host_name: Str, id: Str, status: host.ApplyStatus, verified: Bool, cause: Str? = null) -> host.ApplyResult {
  host.ApplyResult(id: id, host: host_name, status: status, verified: verified, cause: cause)
}

pure parse_or_zero(text_value: Str) -> Int {
  match text_value.parse_int() {
    Ok(value) => value,
    Err(_) => 0,
  }
}

pure duration_ms(value: Duration) -> Int {
  let text_value = f"{value}"
  if text_value.ends_with("ms") {
    return parse_or_zero(text_value.byte_slice(0, text_value.byte_len() - 2))
  }
  if text_value.ends_with("s") {
    return parse_or_zero(text_value.byte_slice(0, text_value.byte_len() - 1)) * 1000
  }
  if text_value.ends_with("m") {
    return parse_or_zero(text_value.byte_slice(0, text_value.byte_len() - 1)) * 60000
  }
  0
}

proc created(session: transport.Session, spec: model.CommandSpec, elevate: List[Str] = []) -> Result[Bool?, Error] {
  let creates_path = spec.creates
  if creates_path == null {
    return Ok(null)
  }
  match remote.inspect_path(session, creates_path ?? p"/", elevate) {
    Ok(host.Found(_)) => Ok(true),
    Ok(host.Missing) => Ok(false),
    _ => Ok(null),
  }
}

proc unless_satisfied(session: transport.Session, spec: model.CommandSpec, run_guard: Bool, elevate: List[Str] = []) -> Result[Bool?, Error] {
  let argv = spec.unless_argv
  if argv == null or ! run_guard {
    return Ok(null)
  }
  let timeout = duration_ms(spec.timeout ?? 0ms)
  let result = execute(session, argv ?? [], if timeout == 0 { null } else { timeout }, elevate)?
  Ok(result.exit_code == 0)
}

## Observe a command without running its guards unless requested.
export proc observe(
  session: transport.Session,
  spec: model.CommandSpec,
  run_guards: Bool,
  elevate: List[Str] = [],
) -> Result[plan.Observed, Error] {
  let creates = created(session, spec, elevate)?
  let guard_result = unless_satisfied(session, spec, run_guards, elevate)?
  Ok(plan.Invocation(plan.CommandFacts(creates_present: creates, unless_satisfied: guard_result)))
}

## Apply one command resource.
export proc apply_remote(
  session: transport.Session,
  host_name: Str,
  spec: model.CommandSpec,
  elevate: List[Str] = [],
  run_guards: Bool = true,
) -> Result[host.ApplyResult, Error] {
  let before = observe(session, spec, run_guards, elevate)?
  let assessment = plan.assess(model.CommandResource(spec), null, before)
  match assessment.prediction {
    plan.Unchanged => return Ok(result(host_name, spec.id, host.Unchanged, true)),
    plan.Blocked => return Ok(result(host_name, spec.id, host.Blocked, false, assessment.cause)),
    plan.Undetermined => return Ok(result(host_name, spec.id, host.Unknown, false, assessment.cause)),
    plan.Changed => {}
  }

  let argv = if spec.argv != null {
    spec.argv ?? []
  } else if spec.shell != null {
    ["sh", "-c", spec.shell ?? ""]
  } else {
    return Ok(result(host_name, spec.id, host.Failed, false, "command needs argv or shell"))
  }
  var command = elevate
  if ! spec.env.is_empty() {
    command += ["env"]
    for {key: key, value: value} in spec.env {
      command += [f"{key}={value}"]
    }
  }
  command += argv
  let timeout = duration_ms(spec.timeout ?? 0ms)
  let wait_ms = if timeout == 0 { null } else { timeout }
  let ran = if spec.stdin_secret != null {
    let reference = spec.stdin_secret ?? model.FromEnv("")
    let data = match secret.resolve(reference) {
      Ok(value) => value,
      Err(failure) => {
        return Ok(result(host_name, spec.id, host.Failed, false, failure.message))
      }
    }
    match transport.exec_stdin(session, command, data, wait_ms) {
      Ok(value) => Ok(value),
      Err(message) => Err(error.failure(message)),
    }
  } else {
    execute(session, command, wait_ms)
  }
  let output = match ran {
    Ok(value) => value,
    Err(failure) => {
      let status = if transport.after_submission(failure.message) { host.Unknown } else { host.Failed }
      return Ok(result(host_name, spec.id, status, false, failure.message))
    }
  }
  if output.exit_code != 0 {
    return Ok(result(host_name, spec.id, host.Failed, false, text(output.stderr).trim()))
  }
  Ok(result(host_name, spec.id, host.Changed, true))
}
