##! Remote user apply logic.

use xinfra.host as host
use xinfra.model as model
use xinfra.plan as plan
use xinfra.remote as remote
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

proc groups_of(session: transport.Session, name: Str) -> Result[List[Str], Error] {
  let result = execute(session, ["id", "-Gn", name])?
  if result.exit_code != 0 {
    return Ok([])
  }
  let text_value = text(result.stdout).trim()
  if text_value == "" {
    return Ok([])
  }
  Ok(text_value.fields())
}

proc observe(session: transport.Session, name: Str) -> Result[plan.Observed, Error] {
  let result = execute(session, ["getent", "passwd", name])?
  if result.exit_code != 0 {
    return Ok(plan.Absent)
  }
  let line = text(result.stdout).trim().lines().get(0) ?? ""
  let parts = line.split(":")
  if parts.len() < 7 {
    return Ok(plan.Unknown)
  }
  let home = if parts[5] == "" { null } else { fp"{parts[5]}" }
  let shell = if parts[6] == "" { null } else { fp"{parts[6]}" }
  let groups = groups_of(session, name)?
  Ok(plan.Account(plan.UserFacts(
    uid: parts[2].parse_int()?,
    gid: parts[3].parse_int()?,
    groups: groups,
    home: home,
    shell: shell,
  )))
}

## Inspect one user without mutating the host.
export proc fact(session: transport.Session, name: Str) -> Result[plan.Observed, Error] {
  observe(session, name)
}

proc group_name_for_gid(session: transport.Session, gid: Int) -> Result[Str?, Error] {
  let result = execute(session, ["getent", "group", f"{gid}"])?
  if result.exit_code != 0 {
    return Ok(null)
  }
  let line = text(result.stdout).trim().lines().get(0) ?? ""
  let name = line.split(":").get(0) ?? ""
  Ok(if name == "" { null } else { name })
}

proc verify(session: transport.Session, host_name: Str, spec: model.UserSpec) -> Result[host.ApplyResult, Error] {
  let after = observe(session, spec.name)?
  let verification = plan.verify(model.UserResource(spec), null, after)
  if verification.ok {
    Ok(result(host_name, spec.id, host.Changed, true))
  } else {
    Ok(result(host_name, spec.id, host.Partial, false, verification.cause))
  }
}

## Apply one user resource; elevation is prefixed to mutating commands.
export proc apply_remote(
  session: transport.Session,
  host_name: Str,
  spec: model.UserSpec,
  elevate: List[Str] = [],
) -> Result[host.ApplyResult, Error] {
  let before = observe(session, spec.name)?
  let assessment = plan.assess(model.UserResource(spec), null, before)
  match assessment.prediction {
    plan.Unchanged => return Ok(result(host_name, spec.id, host.Unchanged, true)),
    plan.Blocked => return Ok(result(host_name, spec.id, host.Blocked, false, assessment.cause)),
    plan.Undetermined => return Ok(result(host_name, spec.id, host.Unknown, false, assessment.cause)),
    plan.Changed => {}
  }

  if spec.state == model.Absent {
    match before {
      plan.Account(facts) => {
        if facts.home != null {
          let home = facts.home ?? p"/"
          match remote.inspect_path(session, home) {
            Ok(host.Found(stat)) => {
              if stat.kind == "dir" and ! stat.empty {
                return Ok(result(
                  host_name,
                  spec.id,
                  host.Blocked,
                  false,
                  f"refusing to remove {spec.name} with non-empty home {home.display()}",
                ))
              }
            }
            _ => {}
          }
        }
      }
      _ => {}
    }
    let removed = execute(session, [@elevate, "userdel", spec.name])?
    if removed.exit_code != 0 {
      return Ok(result(host_name, spec.id, host.Failed, false, text(removed.stderr).trim()))
    }
    return verify(session, host_name, spec)
  }

  match before {
    plan.Absent => {
      var argv = [@elevate, "useradd"]
      if spec.system {
        argv += ["-r"]
      }
      if spec.uid != null {
        argv += ["-u", f"{spec.uid ?? 0}"]
      }
      if spec.gid != null {
        let primary_group = group_name_for_gid(session, spec.gid ?? 0)?
        if primary_group == null {
          return Ok(result(host_name, spec.id, host.Failed, false, f"gid {spec.gid} has no group name"))
        }
        argv += ["-g", primary_group ?? ""]
      } else {
        let same_name = execute(session, ["getent", "group", spec.name])?
        if same_name.exit_code == 0 {
          argv += ["-g", spec.name]
        }
      }
      if spec.home != null {
        argv += ["-d", (spec.home ?? p"/").display()]
      }
      if spec.shell != null {
        argv += ["-s", (spec.shell ?? p"/bin/sh").display()]
      }
      if ! spec.groups.is_empty() {
        argv += ["-G", spec.groups.join(",")]
      }
      if spec.create_home {
        argv += ["-m"]
      } else {
        argv += ["-M"]
      }
      argv += [spec.name]
      let created = execute(session, argv)?
      if created.exit_code != 0 {
        return Ok(result(host_name, spec.id, host.Failed, false, text(created.stderr).trim()))
      }
    }
    plan.Account(facts) => {
      for member in spec.groups {
        if member not in facts.groups {
          let added = execute(session, [@elevate, "usermod", "-a", "-G", member, spec.name])?
          if added.exit_code != 0 {
            return Ok(result(host_name, spec.id, host.Partial, false, text(added.stderr).trim()))
          }
        }
      }
      let home = spec.home
      let shell = spec.shell
      if home != null or shell != null {
        var argv = [@elevate, "usermod"]
        if home != null {
          argv += ["-d", (home ?? p"/").display()]
        }
        if shell != null {
          argv += ["-s", (shell ?? p"/bin/sh").display()]
        }
        argv += [spec.name]
        let updated = execute(session, argv)?
        if updated.exit_code != 0 {
          return Ok(result(host_name, spec.id, host.Partial, false, text(updated.stderr).trim()))
        }
      }
    }
    _ => {}
  }

  verify(session, host_name, spec)
}
