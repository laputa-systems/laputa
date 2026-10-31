##! File apply logic over the host boundary with staged validation.

use xinfra.host
use xinfra.model
use xinfra.plan
use xinfra.remote as remote
use xinfra.secret as secret
use xinfra.staging as staging
use xinfra.transport as transport
use xinfra.validate

proc load_source(ops: host.HostOps, source: validate.PreparedSource) [fs, env, error] -> Result[Bytes, Error] {
  match source {
    validate.Local(value) => {
      let data = ops.read_file_path(value.path)?
      let actual = hash.sha256(data).hex()
      if actual != value.digest {
        return Err(error.failure(f"source {value.path.display()} changed after planning"))
      }

      Ok(data)
    }
    validate.Content(value) => {
      let data = bytes.from_text(value.text)
      if hash.sha256(data).hex() != value.digest {
        return Err(error.failure("prepared content digest does not match"))
      }

      Ok(data)
    }
    validate.Templated(value) => {
      let data = bytes.from_text(value.text)
      if hash.sha256(data).hex() != value.digest {
        return Err(error.failure("rendered template digest does not match"))
      }

      Ok(data)
    }
    validate.Secret(reference) => ops.resolve_secret(reference),
  }
}

proc verify_after(
  ops: host.HostOps,
  spec: model.FileSpec,
  source: validate.PreparedSource,
  digest: Str,
) [fs, env, error] -> host.ApplyResult {
  let verification_source = validate.Local(validate.LocalSource(path: spec.path, digest: digest))
  match ops.inspect_path(spec.path) {
    Err(failure) => host.result(
      ops,
      spec.id,
      host.Unknown,
      verified: false,
      cause: f"inspect after apply failed: {failure.message}",
    ),
    Ok(inspection) => {
      let verification = plan.verify(model.File(spec), verification_source, host.observed(inspection))
      if verification.ok {
        host.result(ops, spec.id, host.Changed, verified: true)
      } else {
        host.result(ops, spec.id, host.Partial, verified: false, cause: verification.cause)
      }
    },
  }
}

proc finish_failure(
  ops: host.HostOps,
  spec: model.FileSpec,
  before: host.Inspection,
  status: host.ApplyStatus,
  failure: Error,
) [fs, env, error] -> host.ApplyResult {
  match ops.inspect_path(spec.path) {
    Err(_) => host.result(ops, spec.id, host.Unknown, verified: false, cause: failure.message),
    Ok(after) => {
      if before == after {
        host.result(ops, spec.id, status, verified: false, cause: failure.message)
      } else {
        host.result(ops, spec.id, host.Partial, verified: false, cause: failure.message)
      }
    },
  }
}

proc verify_removed(ops: host.HostOps, spec: model.FileSpec) [fs, env, error] -> host.ApplyResult {
  match ops.inspect_path(spec.path) {
    Err(failure) => host.result(
      ops,
      spec.id,
      host.Unknown,
      verified: false,
      cause: f"inspect after apply failed: {failure.message}",
    ),
    Ok(inspection) => {
      let verification = plan.verify(model.File(spec), null, host.observed(inspection))
      if verification.ok {
        host.result(ops, spec.id, host.Changed, verified: true)
      } else {
        host.result(ops, spec.id, host.Partial, verified: false, cause: verification.cause)
      }
    },
  }
}

proc apply_content(
  ops: host.HostOps,
  spec: model.FileSpec,
  source: validate.PreparedSource,
  before: host.Inspection,
  data: Bytes,
) [fs, env, error] -> host.ApplyResult {
  let digest = hash.sha256(data).hex()
  let staged = match ops.reserve_staging(spec.path) {
    Ok(value) => value,
    Err(failure) => {
      return host.failed(ops, spec.id, f"staging failed: {failure.message}")
    },
  }
  defer {
    let _ = ops.remove_path(staged)
  }

  match ops.write_staging(staged, data) {
    Err(failure) => {
      return host.result(
        ops,
        spec.id,
        host.Partial,
        verified: false,
        cause: f"transfer failed: {failure.message}",
      )
    }
    Ok(_) => {}
  }

  match ops.digest_path(staged) {
    Err(failure) => {
      return host.failed(ops, spec.id, f"staged digest failed: {failure.message}")
    },
    Ok(actual) => {
      if actual != digest {
        return host.failed(ops, spec.id, "staged bytes do not match the intended digest")
      }
    },
  }

  match ops.set_metadata(staged, spec.mode, spec.owner, spec.group) {
    Err(failure) => {
      return host.failed(ops, spec.id, f"staged metadata failed: {failure.message}")
    },
    Ok(_) => {}
  }

  if spec.validate != null {
    let validation = spec.validate ?? model.Validation(argv: [])
    match ops.validate(validation.argv, staged) {
      Err(failure) => {
        return host.failed(ops, spec.id, f"validation failed: {failure.message}")
      },
      Ok(_) => {}
    }
  }

  match ops.promote(staged, spec.path) {
    Err(failure) => {
      return finish_failure(ops, spec, before, host.Failed, failure)
    }
    Ok(_) => {}
  }

  verify_after(ops, spec, source, digest)
}

## Applies one file resource and verifies the promoted state.
export proc apply(
  ops: host.HostOps,
  spec: model.FileSpec,
  source: validate.PreparedSource?,
) [fs, env, error] -> host.ApplyResult {
  let inspection = match ops.inspect_path(spec.path) {
    Ok(value) => value,
    Err(failure) => {
      return host.failed(ops, spec.id, f"inspect failed: {failure.message}")
    },
  }
  let assessment = plan.assess(model.File(spec), source, host.observed(inspection))
  match assessment.prediction {
    plan.Unchanged => {
      return host.result(ops, spec.id, host.Unchanged, verified: true)
    },
    plan.Blocked => {
      return host.result(ops, spec.id, host.Blocked, verified: false, cause: assessment.cause)
    }
    plan.Changed => {}
    plan.Undetermined => {
      if source == null {
        return host.failed(ops, spec.id, "a present file needs a prepared source")
      }
    }
  }

  if spec.state == model.Absent {
    let secure = match ops.parent_secure(spec.path.parent(), spec.owner) {
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

    let attempted = try {
      ops.remove_path(spec.path)?
    }
    match attempted {
      Ok(_) => {
        return verify_removed(ops, spec)
      },
      Err(failure) => {
        return finish_failure(ops, spec, inspection, host.Failed, failure)
      },
    }
  }

  if source == null {
    return host.failed(ops, spec.id, "a present file needs a prepared source")
  }

  let secure = match ops.parent_secure(spec.path.parent(), spec.owner) {
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

  let data = match load_source(ops, source) {
    Ok(value) => value,
    Err(failure) => {
      return host.failed(ops, spec.id, f"source failed: {failure.message}")
    },
  }
  let actual = hash.sha256(data).hex()
  match inspection {
    host.Found(stat) => {
      let owner_matches = spec.owner == null or spec.owner == stat.owner
      let group_matches = spec.group == null or spec.group == stat.group
      if stat.kind == "file" and stat.mode == spec.mode and owner_matches and group_matches and stat.digest == actual {
        return host.result(ops, spec.id, host.Unchanged, verified: true)
      }
    }
    host.Missing => {}
  }
  apply_content(ops, spec, source, inspection, data)
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
  spec: model.FileSpec,
  source: validate.PreparedSource,
  digest: Str,
  elevate: List[Str] = [],
) [fs, env, process, error, io] -> host.ApplyResult {
  let verification_source = validate.Local(validate.LocalSource(path: spec.path, digest: digest))
  match remote.inspect_path(session, spec.path, elevate) {
    Err(failure) => remote_result(host_name, spec.id, host.Unknown, false, f"inspect after apply failed: {failure.message}"),
    Ok(inspection) => {
      let verification = plan.verify(model.File(spec), verification_source, host.observed(inspection))
      if verification.ok {
        remote_result(host_name, spec.id, host.Changed, true)
      } else {
        remote_result(host_name, spec.id, host.Partial, false, verification.cause)
      }
    },
  }
}

proc remote_finish_failure(
  session: transport.Session,
  host_name: Str,
  spec: model.FileSpec,
  before: host.Inspection,
  status: host.ApplyStatus,
  failure: Error,
  elevate: List[Str] = [],
) [fs, env, process, error, io] -> host.ApplyResult {
  match remote.inspect_path(session, spec.path, elevate) {
    Err(_) => remote_result(host_name, spec.id, host.Unknown, false, failure.message),
    Ok(after) => {
      if before == after {
        remote_result(host_name, spec.id, status, false, failure.message)
      } else {
        remote_result(host_name, spec.id, host.Partial, false, failure.message)
      }
    },
  }
}

proc remote_verify_removed(
  session: transport.Session,
  host_name: Str,
  spec: model.FileSpec,
  elevate: List[Str] = [],
) [fs, env, process, error, io] -> host.ApplyResult {
  match remote.inspect_path(session, spec.path, elevate) {
    Err(failure) => remote_result(host_name, spec.id, host.Unknown, false, f"inspect after apply failed: {failure.message}"),
    Ok(inspection) => {
      let verification = plan.verify(model.File(spec), null, host.observed(inspection))
      if verification.ok {
        remote_result(host_name, spec.id, host.Changed, true)
      } else {
        remote_result(host_name, spec.id, host.Partial, false, verification.cause)
      }
    },
  }
}

proc remote_apply_content(
  session: transport.Session,
  host_name: Str,
  spec: model.FileSpec,
  source: validate.PreparedSource,
  before: host.Inspection,
  elevate: List[Str] = [],
) [fs, env, process, error, io] -> host.ApplyResult {
  let expected = match secret.digest(source) {
    Ok(value) => value,
    Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"secret failed: {failure.message}") },
  }

  let staged = match remote.reserve_staging(session, spec.path, elevate) {
    Ok(value) => value,
    Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"staging failed: {failure.message}") },
  }
  defer {
    let _ = remote.remove_path(session, staged, elevate)
  }

  match staging.write(session, staged, source, elevate) {
    Err(failure) => { return remote_result(host_name, spec.id, host.Partial, false, f"transfer failed: {failure.message}") },
    Ok(_) => {}
  }

  match remote.digest_path(session, staged, elevate) {
    Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"staged digest failed: {failure.message}") },
    Ok(actual) => {
      if actual != expected {
        return remote_result(host_name, spec.id, host.Failed, false, "staged bytes do not match the intended digest")
      }
    },
  }

  let effective_owner = match before {
    host.Found(stat) => match spec.owner {
      null => stat.owner,
      value => value,
    },
    host.Missing => spec.owner,
  }
  let effective_group = match before {
    host.Found(stat) => match spec.group {
      null => stat.group,
      value => value,
    },
    host.Missing => spec.group,
  }
  let staged_mode = if secret.is_secret(source) { 0o600 } else { spec.mode }
  match remote.set_metadata(session, staged, staged_mode, effective_owner, effective_group, elevate) {
    Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"staged metadata failed: {failure.message}") },
    Ok(_) => {}
  }

  if spec.validate != null {
    let validation = spec.validate ?? model.Validation(argv: [])
    match staging.validate(session, validation.argv, staged, elevate) {
      Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"validation failed: {failure.message}") },
      Ok(_) => {}
    }
  }

  match remote.inspect_path(session, staged, elevate) {
    Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"staged inspect failed: {failure.message}") },
    Ok(host.Found(stat)) => {
      if stat.kind != "file" {
        return remote_result(host_name, spec.id, host.Failed, false, "staged object is not a regular file")
      }
    }
    Ok(host.Missing) => { return remote_result(host_name, spec.id, host.Failed, false, "staged object disappeared") },
  }

  match remote.promote(session, staged, spec.path, elevate) {
    Err(failure) => { return remote_finish_failure(session, host_name, spec, before, host.Failed, failure, elevate) },
    Ok(_) => {}
  }
  if secret.is_secret(source) and spec.mode != 0o600 {
    match remote.set_metadata(session, spec.path, spec.mode, effective_owner, effective_group, elevate) {
      Err(failure) => { return remote_result(host_name, spec.id, host.Partial, false, f"final metadata failed: {failure.message}") },
      Ok(_) => {}
    }
  }

  remote_verify_after(session, host_name, spec, source, expected, elevate)
}

## Applies one file resource over a remote session.
export proc apply_remote(
  session: transport.Session,
  host_name: Str,
  spec: model.FileSpec,
  source: validate.PreparedSource?,
  elevate: List[Str] = [],
) [fs, env, process, error, io] -> host.ApplyResult {
  let inspection = match remote.inspect_path(session, spec.path, elevate) {
    Ok(value) => value,
    Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"inspect failed: {failure.message}") },
  }
  if source != null and secret.is_secret(source ?? validate.Secret(model.FromEnv(""))) {
    let expected = match secret.digest(source ?? validate.Secret(model.FromEnv(""))) {
      Ok(value) => value,
      Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"secret failed: {failure.message}") },
    }
    match inspection {
      host.Found(stat) => {
        let owner_matches = spec.owner == null or spec.owner == stat.owner
        let group_matches = spec.group == null or spec.group == stat.group
        if stat.kind == "file" and stat.mode == spec.mode and owner_matches and group_matches and stat.digest == expected {
          return remote_result(host_name, spec.id, host.Unchanged, true)
        }
      }
      host.Missing => {}
    }
  }
  let assessment = plan.assess(model.File(spec), source, host.observed(inspection))
  match assessment.prediction {
    plan.Unchanged => { return remote_result(host_name, spec.id, host.Unchanged, true) },
    plan.Blocked => { return remote_result(host_name, spec.id, host.Blocked, false, assessment.cause) },
    plan.Changed => {}
    plan.Undetermined => {
      if source == null {
        return remote_result(host_name, spec.id, host.Failed, false, "a present file needs a prepared source")
      }
    }
  }

  if spec.state == model.Absent {
    let secure = match remote.parent_secure(session, spec.path.parent(), spec.owner, elevate) {
      Ok(value) => value,
      Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"parent check failed: {failure.message}") },
    }
    if ! secure {
      return remote_result(host_name, spec.id, host.Blocked, false, f"parent of {spec.path.display()} is not a trusted directory")
    }
    let attempted = try {
      remote.remove_path(session, spec.path, elevate)?
    }
    return match attempted {
      Ok(_) => remote_verify_removed(session, host_name, spec, elevate),
      Err(failure) => remote_finish_failure(session, host_name, spec, inspection, host.Failed, failure, elevate),
    }
  }

  if source == null {
    return remote_result(host_name, spec.id, host.Failed, false, "a present file needs a prepared source")
  }

  let secure = match remote.parent_secure(session, spec.path.parent(), spec.owner, elevate) {
    Ok(value) => value,
    Err(failure) => { return remote_result(host_name, spec.id, host.Failed, false, f"parent check failed: {failure.message}") },
  }
  if ! secure {
    return remote_result(host_name, spec.id, host.Blocked, false, f"parent of {spec.path.display()} is not a trusted directory")
  }

  remote_apply_content(session, host_name, spec, source, inspection, elevate)
}
