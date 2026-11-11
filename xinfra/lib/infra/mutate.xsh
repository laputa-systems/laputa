##! Changing host state. Every function here runs only from apply, after a
##! fresh observation and comparison, and reports a typed step error that says
##! whether the step did not take effect, left earlier steps applied, or may
##! or may not have happened.

use infra.compare
use infra.content
use infra.fact
use infra.model
use infra.outcome
use infra.probe
use infra.scripts
use infra.transport

const nul = "\0"

pure failure(phase: outcome.Phase, message: Str, applied: Bool) -> outcome.StepError {
  if applied { outcome.StepError.Partial(phase, message) } else { outcome.StepError.Failed(phase, message) }
}

pure unknown(phase: outcome.Phase, message: Str) -> outcome.StepError {
  outcome.StepError.Unknown(phase, message)
}

pure stderr_text(execution: transport.Execution) -> Str {
  let text = execution.stderr.utf8() ?? "(stderr is not text)"
  if text.trim() == "" { f"exit {execution.code}" } else { f"exit {execution.code}: {text.trim()}" }
}

pure transport_failure(phase: outcome.Phase, error: transport.TransportError, applied: Bool) -> outcome.StepError {
  match error {
    transport.TransportError.Interrupted {message} => unknown(phase, message)
    transport.TransportError.Abnormal {message} => unknown(phase, message)
    transport.TransportError.NotSubmitted {message} => failure(phase, message, applied)
    transport.TransportError.Refused {message} => failure(phase, message, applied)
    transport.TransportError.Unreachable {message} => failure(phase, message, applied)
  }
}

proc output(
  connection: transport.Connection,
  phase: outcome.Phase,
  operation: scripts.Operation,
  args: List[Str],
  applied: Bool,
  stdin: Bytes? = null,
  stdin_path: Path? = null,
  timeout_ms: Int? = null,
) [fs, process, error] -> Result[transport.Execution, outcome.StepError] {
  match transport.exec(connection, operation, args, privileged: true, stdin:, stdin_path:, timeout_ms:) {
    Err(error) => Err(transport_failure(phase, error, applied))
    Ok(execution) => {
      if execution.code == 0 {
        Ok(execution)
      } else {
        Err(failure(phase, stderr_text(execution), applied))
      }
    }
  }
}

proc step(
  connection: transport.Connection,
  phase: outcome.Phase,
  operation: scripts.Operation,
  args: List[Str],
  applied: Bool,
  stdin: Bytes? = null,
  stdin_path: Path? = null,
  timeout_ms: Int? = null,
) [fs, process, error] -> Result[Unit, outcome.StepError] {
  let _ = output(connection, phase, operation, args, applied, stdin:, stdin_path:, timeout_ms:)?
}

## The directory that holds a path. The parent of a top-level name is `/`.
export pure parent_of(location: Str) -> Str {
  let parts = location.split("/")
  let kept = parts[0..parts.len() - 1].join("/")
  if kept == "" { "/" } else { kept }
}

pure owner_spec(owner: Str?, group_name: Str?) -> Str {
  let user_part = owner ?? ""
  let group_part = group_name ?? ""
  if user_part != "" and group_part != "" {
    f"{user_part}:{group_part}"
  } else if user_part != "" {
    user_part
  } else if group_part != "" {
    f":{group_part}"
  } else {
    ""
  }
}

pure changes_field(drift: compare.Drift, field: Str) -> Bool {
  drift.changes |> any { |change| change.field == field }
}

proc apply_directory(connection: transport.Connection, spec: model.DirectorySpec, drift: compare.Drift) [fs, process, error] -> Result[Unit, outcome.StepError] {
  if drift.act == .Remove {
    step(connection, .Apply, .RemoveDirectory, [spec.path], false)?
    return
  }

  var applied = false
  if drift.act == .Create {
    let initial = if spec.mode == null { "" } else { compare.octal(0o700) }
    let parents = if spec.parents { "1" } else { "0" }
    step(connection, .Apply, .MakeDirectory, [spec.path, parents, initial], false)?
    applied = true
  }

  let owner = owner_spec(spec.owner, spec.group)
  if owner != "" and (drift.act == .Create or changes_field(drift, "owner") or changes_field(drift, "group")) {
    step(connection, .Apply, .ChangeOwner, [owner, spec.path], applied)?
    applied = true
  }

  if spec.mode != null and (drift.act == .Create or changes_field(drift, "mode")) {
    step(connection, .Apply, .ChangeMode, [compare.octal(spec.mode), spec.path], applied)?
  }
}

pure existing_info(state: fact.PathState) -> fact.PathInfo? {
  match state {
    fact.Found(info) => info
    else => null
  }
}

pure staged_path(execution: transport.Execution) -> Result[Str, outcome.StepError] {
  let text = execution.stdout.utf8() ?? ""
  match probe.decode_hex(text.trim()) {
    Ok(found) => {
      if found.starts_with("/") { Ok(found) } else { Err(failure(.Stage, "the staging path is not absolute", false)) }
    }
    Err(_) => Err(failure(.Stage, "the staging path could not be read", false))
  }
}

proc discard(connection: transport.Connection, stage: Str, cause: outcome.StepError) [fs, process, error] -> outcome.StepError {
  match step(connection, .Cleanup, .DiscardStage, [stage], false) {
    Ok(_) => cause
    Err(cleanup) => {
      match cause {
        outcome.StepError.Failed {phase, message} => outcome.StepError.Failed(phase, f"{message}; the staging file {stage} could not be removed: {cleanup.message}")
        outcome.StepError.Partial {phase, message} => outcome.StepError.Partial(phase, f"{message}; the staging file {stage} could not be removed: {cleanup.message}")
        outcome.StepError.Unknown {phase, message} => outcome.StepError.Unknown(phase, f"{message}; the staging file {stage} could not be removed: {cleanup.message}")
      }
    }
  }
}

pure validator_argv(validate: List[Str], stage: Str) -> List[Str] {
  validate |> map { |word| if word == "{}" { stage } else { word } } |> collect()
}

proc stream_content(
  connection: transport.Connection,
  stage: Str,
  source: model.Content,
  expected: compare.Material,
) [fs, env, process, error] -> Result[Unit, outcome.StepError] {
  let streamed = content.streamed_path(source)
  let data = match content.inline_bytes(source) {
    Ok(found) => found
    Err(error) => {
      return Err(failure(.Stage, error.message, false))
    }
  }

  if streamed != null {
    let measured = match content.measure(source) {
      Ok(found) => found
      Err(error) => {
        return Err(failure(.Stage, error.message, false))
      }
    }

    if measured.digest != expected.digest {
      return Err(failure(.Stage, f"{streamed} changed after it was measured", false))
    }
  }

  step(connection, .Stage, .WriteStage, [stage], false, stdin: data, stdin_path: streamed, timeout_ms: connection.transfer_timeout_ms)?
  let inspected = output(connection, .Stage, .InspectStage, [stage], false)?
  let table = inspected.stdout.utf8() ?? ""
  if f"digest {expected.digest}" not in table.lines() {
    return Err(failure(.Stage, "the staged copy does not match the intended content", false))
  }

  if f"size {expected.size}" not in table.lines() {
    return Err(failure(.Stage, "the staged copy has a different size than the intended content", false))
  }
}

proc replace_file(
  connection: transport.Connection,
  spec: model.FileSpec,
  state: fact.PathState,
  source: model.Content,
  expected: compare.Material,
) [fs, env, process, error] -> Result[Unit, outcome.StepError] {
  let existing = existing_info(state)
  let owner = owner_spec(spec.owner ?? existing?.owner ?? "", spec.group ?? existing?.group ?? "")
  let mode = spec.mode ?? existing?.mode ?? 0o644
  let created = output(connection, .Stage, .CreateStage, [parent_of(spec.path)], false)?
  let stage = staged_path(created)?
  match stream_content(connection, stage, source, expected) {
    Err(error) => {
      return Err(discard(connection, stage, error))
    }
    Ok(_) => {}
  }

  match step(connection, .Stage, .FinishStage, [stage, owner, compare.octal(mode)], false) {
    Err(error) => {
      return Err(discard(connection, stage, error))
    }
    Ok(_) => {}
  }

  if ! spec.validate.is_empty() {
    match step(connection, .Validate, .RunArgv, validator_argv(spec.validate, stage), false) {
      Err(error) => {
        return Err(discard(connection, stage, error))
      }
      Ok(_) => {}
    }
  }

  match step(connection, .Promote, .PromoteStage, [stage, spec.path], false) {
    Err(error) => {
      return Err(discard(connection, stage, error))
    }
    Ok(_) => {}
  }
}

proc apply_file(
  connection: transport.Connection,
  spec: model.FileSpec,
  state: fact.PathState,
  drift: compare.Drift,
  source: model.Content?,
  expected: compare.Material?,
) [fs, env, process, error] -> Result[Unit, outcome.StepError] {
  if drift.act == .Remove {
    step(connection, .Apply, .RemoveFile, [spec.path], false)?
    return
  }

  if drift.act == .Create or changes_field(drift, "content") {
    guard let wanted = source else {
      return Err(failure(.Apply, "a present file has no content source", false))
    }

    guard let material = expected else {
      return Err(failure(.Apply, "the content of the file was not measured", false))
    }

    replace_file(connection, spec, state, wanted, material)?
    return
  }

  let owner = owner_spec(spec.owner, spec.group)
  var applied = false
  if owner != "" and (changes_field(drift, "owner") or changes_field(drift, "group")) {
    step(connection, .Apply, .ChangeOwner, [owner, spec.path], false)?
    applied = true
  }

  if spec.mode != null and changes_field(drift, "mode") {
    step(connection, .Apply, .ChangeMode, [compare.octal(spec.mode), spec.path], applied)?
  }
}

proc apply_link(connection: transport.Connection, spec: model.SymlinkSpec, drift: compare.Drift) [fs, process, error] -> Result[Unit, outcome.StepError] {
  match drift.act {
    compare.Remove => {
      step(connection, .Apply, .RemoveLink, [spec.path], false)?
    }
    compare.Update => {
      step(connection, .Apply, .ReplaceLink, [spec.target, spec.path], false)?
    }
    else => {
      step(connection, .Apply, .MakeLink, [spec.target, spec.path], false)?
    }
  }
}

pure package_argument(spec: model.PackageSpec) -> Str {
  if spec.constraint == null { spec.name } else { f"{spec.name}{spec.constraint.op}{spec.constraint.version}" }
}

proc apply_package(connection: transport.Connection, spec: model.PackageSpec, drift: compare.Drift) [fs, process, error] -> Result[Unit, outcome.StepError] {
  if drift.act == .Remove {
    step(connection, .Apply, .ApkDel, [spec.name], false, timeout_ms: 600000)?
  } else {
    step(connection, .Apply, .ApkAdd, [package_argument(spec)], false, timeout_ms: 600000)?
  }
}

proc refresh_index(connection: transport.Connection) [fs, process, error] -> Result[Unit, outcome.StepError] {
  step(connection, .Apply, .ApkUpdate, [], false, timeout_ms: 600000)?
}

proc apply_group(connection: transport.Connection, spec: model.GroupSpec, drift: compare.Drift) [fs, process, error] -> Result[Unit, outcome.StepError] {
  if drift.act == .Remove {
    step(connection, .Apply, .DeleteGroup, [spec.name], false)?
  } else {
    let gid = if spec.gid == null { "" } else { f"{spec.gid}" }
    step(connection, .Apply, .AddGroup, [spec.name, gid], false)?
  }
}

proc apply_user(connection: transport.Connection, spec: model.UserSpec, state: fact.Fact, drift: compare.Drift) [fs, process, error] -> Result[Unit, outcome.StepError] {
  if drift.act == .Remove {
    step(connection, .Apply, .DeleteUser, [spec.name], false)?
    return
  }

  var applied = false
  var memberships = spec.groups
  if drift.act == .Create {
    let uid = if spec.uid == null { "" } else { f"{spec.uid}" }
    let system_flag = if spec.system { "1" } else { "0" }
    step(connection, .Apply, .AddUser, [spec.name, uid, spec.group ?? "", spec.home ?? "", spec.shell ?? "", system_flag], false)?
    applied = true
  } else {
    let primary = if changes_field(drift, "group") { spec.group ?? "" } else { "" }
    let home = if changes_field(drift, "home") { spec.home ?? "" } else { "" }
    let shell = if changes_field(drift, "shell") { spec.shell ?? "" } else { "" }
    if primary != "" or home != "" or shell != "" {
      step(connection, .Apply, .ModifyUser, [spec.name, primary, home, shell], false)?
      applied = true
    }
  }

  for member in memberships {
    let known = match state {
      fact.OnUser(fact.UserFound(info)) => member in info.memberships or member == (info.group ?? "")
      else => false
    }
    if ! known {
      step(connection, .Apply, .JoinGroup, [spec.name, member], applied)?
      applied = true
    }
  }
}

pure notification(drift: compare.Drift) -> Str? {
  let notices = drift.changes |> where { |change| change.field == "notify" } |> collect()
  if notices.is_empty() { null } else { notices[0].to }
}

pure control_operation(adapter: model.ServiceAdapter) -> scripts.Operation {
  match adapter {
    model.OpenRc => .ControlService
    model.Xinit => .XinitControlService
  }
}

proc apply_service(connection: transport.Connection, spec: model.ServiceSpec, drift: compare.Drift) [fs, process, error] -> Result[Unit, outcome.StepError] {
  var applied = false
  for change in drift.changes {
    if change.field == "enabled" {
      guard spec.adapter == .OpenRc else {
        return Err(failure(.Apply, "xinit has no enable or disable", applied))
      }

      let operation: scripts.Operation = if change.to == "enabled" { .EnableService } else { .DisableService }
      step(connection, .Apply, operation, [spec.name, spec.runlevel], applied)?
      applied = true
    }
  }

  for change in drift.changes {
    if change.field == "running" {
      let action = if change.to == "started" { "start" } else { "stop" }
      step(connection, .Apply, control_operation(spec.adapter), [spec.name, action], applied, timeout_ms: 120000)?
      applied = true
    }
  }

  let notice = notification(drift)
  if notice != null and ! changes_field(drift, "running") {
    step(connection, .Notify, control_operation(spec.adapter), [spec.name, notice], applied, timeout_ms: 120000)?
  }
}

proc apply_command(connection: transport.Connection, spec: model.CommandSpec) [env, fs, process, error] -> Result[Unit, outcome.StepError] {
  var input: Bytes? = null
  if spec.stdin_env != null {
    match env.get(spec.stdin_env) {
      Ok(value) => input = bytes.from_text(value)
      Err(error) => {
        return Err(failure(.Apply, error.message, false))
      }
    }
  }

  let operation = match spec.invocation {
    model.Argv(_) => scripts.RunArgv
    model.Shell(_) => scripts.RunShell
  }
  let args = match spec.invocation {
    model.Argv(argv) => argv
    model.Shell(text) => [text]
  }

  match transport.exec(connection, operation, args, privileged: true, stdin: input, timeout_ms: spec.timeout_ms) {
    Err(error) => Err(transport_failure(.Apply, error, false))
    Ok(execution) => {
      guard execution.code in spec.accept else {
        return Err(failure(.Apply, stderr_text(execution), false))
      }
    }
  }
}

## Make the change a drifted resource needs. `state` is the fact the drift was
## computed from. A file's `source` and `expected` come from `content.measure`
## taken just before this call.
export proc apply(
  connection: transport.Connection,
  resource: model.Resource,
  state: fact.Fact,
  drift: compare.Drift,
  source: model.Content?,
  expected: compare.Material?,
) [fs, env, process, error] -> Result[Unit, outcome.StepError] {
  match resource.spec {
    model.Directory(spec) => apply_directory(connection, spec, drift)
    model.File(spec) => {
      match state {
        fact.OnPath(path_state) => apply_file(connection, spec, path_state, drift, source, expected)
        else => Err(failure(.Apply, "a file was compared with a fact of another kind", false))
      }
    }
    model.Link(spec) => apply_link(connection, spec, drift)
    model.Package(spec) => apply_package(connection, spec, drift)
    model.PackageIndex(_) => refresh_index(connection)
    model.GroupAccount(spec) => apply_group(connection, spec, drift)
    model.UserAccount(spec) => apply_user(connection, spec, state, drift)
    model.Service(spec) => apply_service(connection, spec, drift)
    model.Exec(spec) => apply_command(connection, spec)
  }
}
