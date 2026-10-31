##! Directory apply logic over the host boundary, one level deep.

use xinfra.host
use xinfra.model
use xinfra.plan
use xinfra.remote as remote
use xinfra.transport as transport

proc verify_after(ops: host.HostOps, spec: model.DirectorySpec) [fs, env, error] -> host.ApplyResult {
  match ops.inspect_path(spec.path) {
    Err(failure) => host.result(
      ops,
      spec.id,
      host.Unknown,
      verified: false,
      cause: f"inspect after apply failed: {failure.message}",
    ),
    Ok(inspection) => {
      let verification = plan.verify(model.Directory(spec), null, host.observed(inspection))
      if verification.ok {
        host.result(ops, spec.id, host.Changed, verified: true)
      } else {
        host.result(
          ops,
          spec.id,
          host.Partial,
          verified: false,
          cause: verification.cause,
        )
      }
    },
  }
}

proc finish(
  ops: host.HostOps,
  spec: model.DirectorySpec,
  before: host.Inspection,
  attempted: Result[Unit, Error],
) [fs, env, error] -> host.ApplyResult {
  match attempted {
    Ok(_) => verify_after(ops, spec),
    Err(failure) => {
      match ops.inspect_path(spec.path) {
        Err(_) => host.result(
          ops,
          spec.id,
          host.Unknown,
          verified: false,
          cause: failure.message,
        ),
        Ok(after) => {
          if before == after {
            host.failed(ops, spec.id, failure.message)
          } else {
            host.result(ops, spec.id, host.Partial, verified: false, cause: failure.message)
          }
        },
      }
    },
  }
}

proc secure_parent(ops: host.HostOps, spec: model.DirectorySpec) [fs, env, error] -> Result[Bool, Error] {
  ops.parent_secure(spec.path.parent(), spec.owner)
}

## Applies one directory resource and verifies the resulting state.
export proc apply(ops: host.HostOps, spec: model.DirectorySpec) [fs, env, error] -> host.ApplyResult {
  let inspection = match ops.inspect_path(spec.path) {
    Ok(value) => value,
    Err(failure) => {
      return host.failed(ops, spec.id, f"inspect failed: {failure.message}")
    },
  }
  let assessment = plan.assess(model.Directory(spec), null, host.observed(inspection))
  match assessment.prediction {
    plan.Unchanged => {
      return host.result(ops, spec.id, host.Unchanged, verified: true)
    },
    plan.Blocked => {
      return host.result(ops, spec.id, host.Blocked, verified: false, cause: assessment.cause)
    }
    plan.Undetermined => {
      return host.result(ops, spec.id, host.Unknown, verified: false, cause: assessment.cause)
    }
    plan.Changed => {}
  }

  let secure = match secure_parent(ops, spec) {
    Ok(value) => value,
    Err(failure) => {
      return host.failed(ops, spec.id, f"parent check failed: {failure.message}")
    },
  }
  if ! secure {
    return host.result(
      ops,
      spec.id,
      host.Blocked,
      verified: false,
      cause: f"parent of {spec.path.display()} is not a trusted directory",
    )
  }

  match inspection {
    host.Missing => {
      let attempted = try {
        ops.mkdir_path(spec.path, spec.mode)?
        ops.set_metadata(spec.path, spec.mode, spec.owner, spec.group)?
      }
      finish(ops, spec, inspection, attempted)
    }
    host.Found(stat) => {
      if stat.kind != "dir" {
        return host.result(
          ops,
          spec.id,
          host.Blocked,
          verified: false,
          cause: f"{spec.path.display()} is a {stat.kind}, not a directory",
        )
      }

      let attempted = try {
        if spec.state == model.Absent {
          ops.remove_dir_path(spec.path)?
        } else {
          ops.set_metadata(spec.path, spec.mode, spec.owner, spec.group)?
        }
      }
      finish(ops, spec, inspection, attempted)
    }
  }
}

pure remote_result(
  host_name: Str,
  id: Str,
  status: host.ApplyStatus,
  verified: Bool,
  cause: Str? = null,
) -> host.ApplyResult {
  host.ApplyResult(id: id, host: host_name, status: status, verified: verified, cause: cause)
}

proc remote_verify_after(
  session: transport.Session,
  host_name: Str,
  spec: model.DirectorySpec,
  elevate: List[Str] = [],
) [fs, env, process, error, io] -> host.ApplyResult {
  match remote.inspect_path(session, spec.path, elevate) {
    Err(failure) => remote_result(
      host_name,
      spec.id,
      host.Unknown,
      false,
      f"inspect after apply failed: {failure.message}",
    ),
    Ok(inspection) => {
      let verification = plan.verify(model.Directory(spec), null, host.observed(inspection))
      if verification.ok {
        remote_result(host_name, spec.id, host.Changed, true)
      } else {
        remote_result(host_name, spec.id, host.Partial, false, verification.cause)
      }
    },
  }
}

proc remote_finish(
  session: transport.Session,
  host_name: Str,
  spec: model.DirectorySpec,
  before: host.Inspection,
  attempted: Result[Unit, Error],
  elevate: List[Str] = [],
) [fs, env, process, error, io] -> host.ApplyResult {
  match attempted {
    Ok(_) => remote_verify_after(session, host_name, spec, elevate),
    Err(failure) => match remote.inspect_path(session, spec.path, elevate) {
      Err(_) => remote_result(host_name, spec.id, host.Unknown, false, failure.message),
      Ok(after) => {
        if before == after {
          remote_result(host_name, spec.id, host.Failed, false, failure.message)
        } else {
          remote_result(host_name, spec.id, host.Partial, false, failure.message)
        }
      },
    },
  }
}

## Applies one directory resource over a remote session.
export proc apply_remote(
  session: transport.Session,
  host_name: Str,
  spec: model.DirectorySpec,
  elevate: List[Str] = [],
) [fs, env, process, error, io] -> host.ApplyResult {
  let inspection = match remote.inspect_path(session, spec.path, elevate) {
    Ok(value) => value,
    Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"inspect failed: {failure.message}") },
  }
  let assessment = plan.assess(model.Directory(spec), null, host.observed(inspection))
  match assessment.prediction {
    plan.Unchanged => return remote_result(host_name, spec.id, host.Unchanged, true),
    plan.Blocked => return remote_result(host_name, spec.id, host.Blocked, false, assessment.cause),
    plan.Undetermined => return remote_result(host_name, spec.id, host.Unknown, false, assessment.cause),
    plan.Changed => {}
  }

  let secure = match remote.parent_secure(session, spec.path.parent(), spec.owner, elevate) {
    Ok(value) => value,
    Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"parent check failed: {failure.message}") },
  }
  if ! secure {
    return remote_result(
      host_name,
      spec.id,
      host.Blocked,
      false,
      f"parent of {spec.path.display()} is not a trusted directory",
    )
  }

  match inspection {
    host.Missing => {
      let attempted = try {
        remote.mkdir_path(session, spec.path, spec.mode, elevate)?
        remote.set_metadata(session, spec.path, spec.mode, spec.owner, spec.group, elevate)?
      }
      remote_finish(session, host_name, spec, inspection, attempted, elevate)
    }
    host.Found(stat) => {
      if stat.kind != "dir" {
        return remote_result(
          host_name,
          spec.id,
          host.Blocked,
          false,
          f"{spec.path.display()} is a {stat.kind}, not a directory",
        )
      }

      let attempted = try {
        if spec.state == model.Absent {
          remote.remove_dir_path(session, spec.path, elevate)?
        } else {
          remote.set_metadata(session, spec.path, spec.mode, spec.owner, spec.group, elevate)?
        }
      }
      remote_finish(session, host_name, spec, inspection, attempted, elevate)
    }
  }
}
