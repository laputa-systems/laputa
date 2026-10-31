##! Alpine package apply logic over a remote session.

use xinfra.host as host
use xinfra.model as model
use xinfra.plan as plan
use xinfra.remote as remote
use xinfra.transport as transport

## A package apply result with the index refresh reported separately.
export type PackageApply = {result: host.ApplyResult, refreshed: Bool}

proc execute(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Error] {
  match transport.exec(session, argv) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
  }
}

pure result(host_name: Str, id: Str, status: host.ApplyStatus, verified: Bool, cause: Str? = null) -> host.ApplyResult {
  host.ApplyResult(id: id, host: host_name, status: status, verified: verified, cause: cause)
}

pure base_name(name: Str) -> Str {
  let at = name.find("@")
  if at == null {
    return name
  }
  name.byte_slice(0, at ?? 0)
}

pure package_version(line: Str, name: Str) -> Str? {
  let prefix = f"{name}-"
  let token = line.fields().get(0) ?? ""
  if token.starts_with(prefix) {
    return token.byte_slice(prefix.byte_len())
  }
  null
}

pure valid_constraint(constraint: Str) -> Bool {
  constraint.is_empty() or rx"^[<>=~]*[0-9A-Za-z._-]+$".matches(constraint)
}

pure constraint_target(constraint: Str) -> Str {
  let operators = ["<=", ">=", "~", "<", ">", "="]
  for operator in operators {
    if constraint.starts_with(operator) {
      return constraint.byte_slice(operator.byte_len())
    }
  }
  constraint
}

proc installed_version(session: transport.Session, name: Str) -> Result[Str?, Error] {
  let base = base_name(name)
  let result = execute(session, ["apk", "list", "-I", base])?
  if result.exit_code != 0 {
    return Err(error.failure(result.stderr.utf8() ?? ""))
  }
  let line = (result.stdout.utf8() ?? "").trim().lines().get(0) ?? ""
  Ok(package_version(line, base))
}

proc compare(session: transport.Session, installed: Str, wanted: Str) -> Result[Str, Error] {
  let result = execute(session, ["apk", "version", "-t", installed, wanted])?
  return Err(error.failure(result.stderr.utf8() ?? "")) when result.exit_code != 0
  Ok((result.stdout.utf8() ?? "").trim())
}

proc satisfies(session: transport.Session, installed: Str, constraint: Str) -> Result[Bool, Error] {
  let target = constraint_target(constraint)
  let order = compare(session, installed, target)?
  if constraint.starts_with(">=") {
    return Ok(order == "=" or order == ">")
  }
  if constraint.starts_with("<=") {
    return Ok(order == "=" or order == "<")
  }
  if constraint.starts_with(">") {
    return Ok(order == ">")
  }
  if constraint.starts_with("<") {
    return Ok(order == "<")
  }
  if constraint.starts_with("~") {
    let prefix = f"{target}."
    return Ok(
      installed == target or
      installed.starts_with(prefix) or
      installed.starts_with(f"{target}-") or
      installed.starts_with(f"{target}_"),
    )
  }
  Ok(order == "=")
}

proc observed(session: transport.Session, spec: model.PackageSpec) -> Result[plan.Observed, Error] {
  let version = installed_version(session, spec.name)?
  if version == null {
    return Ok(plan.Absent)
  }
  let installed = version ?? ""
  let satisfied = match spec.constraint {
    null => null,
    constraint => satisfies(session, installed, constraint ?? "")?,
  }
  Ok(plan.Installed(plan.PackageFacts(version: version, satisfies: satisfied)))
}

## Inspect one package without mutating the host.
export proc fact(session: transport.Session, spec: model.PackageSpec) -> Result[plan.Observed, Error] {
  observed(session, spec)
}

proc verify(session: transport.Session, host_name: Str, spec: model.PackageSpec) -> Result[host.ApplyResult, Error] {
  let after = observed(session, spec)?
  let verification = plan.verify(model.Package(spec), null, after)
  if verification.ok {
    Ok(result(host_name, spec.id, host.Changed, true))
  } else {
    Ok(result(host_name, spec.id, host.Partial, false, verification.cause))
  }
}

## Apply one package resource; elevation is prefixed to mutating apk commands.
export proc apply_remote(
  session: transport.Session,
  host_name: Str,
  spec: model.PackageSpec,
  elevate: List[Str] = [],
) -> Result[PackageApply, Error] {
  if spec.constraint != null and ! valid_constraint(spec.constraint ?? "") {
    return Ok(PackageApply(
      result: result(host_name, spec.id, host.Failed, false, "unsupported package constraint"),
      refreshed: false,
    ))
  }

  let before = observed(session, spec)?
  let assessment = plan.assess(model.Package(spec), null, before)
  match assessment.prediction {
    plan.Unchanged => return Ok(PackageApply(result: result(host_name, spec.id, host.Unchanged, true), refreshed: false)),
    plan.Blocked => return Ok(PackageApply(result: result(host_name, spec.id, host.Blocked, false, assessment.cause), refreshed: false)),
    plan.Undetermined => return Ok(PackageApply(result: result(host_name, spec.id, host.Unknown, false, assessment.cause), refreshed: false)),
    plan.Changed => {}
  }

  var refreshed = false
  if spec.state == model.Absent {
    let removed = execute(session, [@elevate, "apk", "del", base_name(spec.name)])?
    if removed.exit_code != 0 {
      return Ok(PackageApply(
        result: result(host_name, spec.id, host.Failed, false, (removed.stderr.utf8() ?? "").trim()),
        refreshed: false,
      ))
    }
  } else {
    if spec.refresh_index {
      let updated = execute(session, [@elevate, "apk", "update"])?
      if updated.exit_code != 0 {
        return Ok(PackageApply(
          result: result(host_name, spec.id, host.Failed, false, (updated.stderr.utf8() ?? "").trim()),
          refreshed: false,
        ))
      }
      refreshed = true
    }
    let constraint = spec.constraint ?? ""
    let wanted = if constraint == "" {
      spec.name
    } else if constraint.starts_with("=") or constraint.starts_with("<") or constraint.starts_with(">") or constraint.starts_with("~") {
      f"{spec.name}{constraint}"
    } else {
      f"{spec.name}={constraint}"
    }
    let installed = execute(session, [@elevate, "apk", "add", "--no-progress", wanted])?
    if installed.exit_code != 0 {
      return Ok(PackageApply(
        result: result(host_name, spec.id, host.Failed, false, (installed.stderr.utf8() ?? "").trim()),
        refreshed: refreshed,
      ))
    }
  }

  let verified = verify(session, host_name, spec)?
  Ok(PackageApply(result: verified, refreshed: refreshed))
}
