##! Remote OpenRC service apply logic.

use xinfra.host as host
use xinfra.model as model
use xinfra.plan as plan
use xinfra.transport as transport

proc execute(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Error] {
  match transport.exec(session, argv) {
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

pure enabled_in(text_value: Str, name: Str) -> Bool {
  for line in text_value.lines() {
    let words = line.words()
    if ! words.is_empty() and words[0] == name {
      return true
    }
  }
  false
}

proc observe(session: transport.Session, name: Str) -> Result[plan.Observed, Error] {
  let status = execute(session, ["rc-service", name, "status"])?
  let started = status.exit_code == 0
  let stopped = status.exit_code == 3
  if ! started and ! stopped {
    return Ok(plan.Unknown)
  }
  let listing = execute(session, ["rc-update", "show"])?
  if listing.exit_code != 0 {
    return Ok(plan.Running(plan.ServiceFacts(started: started, enabled: null)))
  }
  Ok(plan.Running(plan.ServiceFacts(
    started: started,
    enabled: enabled_in(text(listing.stdout), name),
  )))
}

## Inspect one service without mutating the host.
export proc fact(session: transport.Session, name: Str) -> Result[plan.Observed, Error] {
  observe(session, name)
}

proc verify(session: transport.Session, host_name: Str, spec: model.ServiceSpec) -> Result[host.ApplyResult, Error] {
  let after = observe(session, spec.name)?
  let verification = plan.verify(model.ServiceResource(spec), null, after)
  if verification.ok {
    Ok(result(host_name, spec.id, host.Changed, true))
  } else {
    Ok(result(host_name, spec.id, host.Partial, false, verification.cause))
  }
}

## Apply one service resource; elevation is prefixed to mutating commands.
export proc apply_remote(
  session: transport.Session,
  host_name: Str,
  spec: model.ServiceSpec,
  elevate: List[Str] = [],
) -> Result[host.ApplyResult, Error] {
  let before = observe(session, spec.name)?
  let assessment = plan.assess(model.ServiceResource(spec), null, before)
  match assessment.prediction {
    plan.Unchanged => return Ok(result(host_name, spec.id, host.Unchanged, true)),
    plan.Blocked => return Ok(result(host_name, spec.id, host.Blocked, false, assessment.cause)),
    plan.Undetermined => return Ok(result(host_name, spec.id, host.Unknown, false, assessment.cause)),
    plan.Changed => {}
  }

  let action = if spec.state == model.Started { "start" } else { "stop" }
  let changed = execute(session, [@elevate, "rc-service", spec.name, action])?
  if changed.exit_code != 0 {
    return Ok(result(host_name, spec.id, host.Failed, false, text(changed.stderr).trim()))
  }

  let currently_enabled = match before {
    plan.Running(facts) => facts.enabled,
    _ => null,
  }
  if spec.enabled != null and currently_enabled != spec.enabled {
    let enable = if spec.enabled ?? false { "add" } else { "del" }
    let updated = execute(session, [@elevate, "rc-update", enable, spec.name, "default"])?
    if updated.exit_code != 0 {
      return Ok(result(host_name, spec.id, host.Partial, false, text(updated.stderr).trim()))
    }
  }

  verify(session, host_name, spec)
}

## Restart one service, used by coalesced change notifications.
export proc restart_remote(
  session: transport.Session,
  name: Str,
  elevate: List[Str] = [],
) -> Result[host.ApplyResult, Error] {
  let restarted = execute(session, [@elevate, "rc-service", name, "restart"])?
  if restarted.exit_code != 0 {
    return Ok(result(name, name, host.Failed, false, text(restarted.stderr).trim()))
  }
  Ok(result(name, name, host.Changed, true))
}

## Reload one service, used by coalesced change notifications.
export proc reload_remote(
  session: transport.Session,
  name: Str,
  elevate: List[Str] = [],
) -> Result[host.ApplyResult, Error] {
  let reloaded = execute(session, [@elevate, "rc-service", name, "reload"])?
  if reloaded.exit_code != 0 {
    return Ok(result(name, name, host.Failed, false, text(reloaded.stderr).trim()))
  }
  Ok(result(name, name, host.Changed, true))
}
