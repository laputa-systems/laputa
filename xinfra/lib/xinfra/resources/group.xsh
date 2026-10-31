##! Remote group apply logic.

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

proc observe(session: transport.Session, name: Str) -> Result[plan.Observed, Error] {
  let queried = execute(session, ["getent", "group", name])?
  if queried.exit_code != 0 {
    return Ok(plan.Absent)
  }
  let line = text(queried.stdout).trim().lines().get(0) ?? ""
  let parts = line.split(":")
  if parts.len() < 4 {
    return Ok(plan.Unknown)
  }
  Ok(plan.Role(plan.GroupFacts(gid: parts[2].parse_int()?)))
}

## Inspect one group without mutating the host.
export proc fact(session: transport.Session, name: Str) -> Result[plan.Observed, Error] {
  observe(session, name)
}

proc verify(session: transport.Session, host_name: Str, spec: model.GroupSpec) -> Result[host.ApplyResult, Error] {
  let after = observe(session, spec.name)?
  let verification = plan.verify(model.GroupResource(spec), null, after)
  if verification.ok {
    Ok(result(host_name, spec.id, host.Changed, true))
  } else {
    Ok(result(host_name, spec.id, host.Partial, false, verification.cause))
  }
}

## Apply one group resource; elevation is prefixed to mutating commands.
export proc apply_remote(
  session: transport.Session,
  host_name: Str,
  spec: model.GroupSpec,
  elevate: List[Str] = [],
) -> Result[host.ApplyResult, Error] {
  let before = observe(session, spec.name)?
  let assessment = plan.assess(model.GroupResource(spec), null, before)
  match assessment.prediction {
    plan.Unchanged => return Ok(result(host_name, spec.id, host.Unchanged, true)),
    plan.Blocked => return Ok(result(host_name, spec.id, host.Blocked, false, assessment.cause)),
    plan.Undetermined => return Ok(result(host_name, spec.id, host.Unknown, false, assessment.cause)),
    plan.Changed => {}
  }

  if spec.state == model.Absent {
    let removed = execute(session, [@elevate, "groupdel", spec.name])?
    if removed.exit_code != 0 {
      return Ok(result(host_name, spec.id, host.Failed, false, text(removed.stderr).trim()))
    }
    return verify(session, host_name, spec)
  }

  var argv = [@elevate, "groupadd"]
  if spec.system {
    argv += ["-r"]
  }
  if spec.gid != null {
    argv += ["-g", f"{spec.gid ?? 0}"]
  }
  argv += [spec.name]
  let created = execute(session, argv)?
  if created.exit_code != 0 {
    return Ok(result(host_name, spec.id, host.Failed, false, text(created.stderr).trim()))
  }
  verify(session, host_name, spec)
}
