##! Constructors for the initial resource set. Each validates its arguments and
##! returns a value; none touches a host or the local machine.

use infra.check
use infra.model

pure require_args(what: Str, id: Str, needs: List[Str]) -> Result[Unit, Error] {
  ctx f"{what} {id}" {
    check.identifier_ok(id)?
    check.needs_ok(needs)?
  }
}

pure principals(owner: Str?, group_name: Str?) -> Result[Unit, Error] {
  if owner != null {
    check.principal_ok("owner", owner)?
  }

  if group_name != null {
    check.principal_ok("group", group_name)?
  }
}

pure optional_id(what: Str, value: Int?) -> Result[Unit, Error] {
  if value != null {
    check.id_number_ok(what, value)?
  }
}

pure optional_path(what: Str, value: Str?) -> Result[Unit, Error] {
  if value != null {
    check.path_ok(what, value)?
  }
}

pure optional_account(what: Str, value: Str?) -> Result[Unit, Error] {
  if value != null {
    check.account_ok(what, value)?
  }
}

pure modes(mode: Int?) -> Result[Unit, Error] {
  if mode != null {
    check.mode_ok(mode)?
  }
}

## Declare a directory. Without `parents` the parent must already exist;
## `Absent` removes only an empty directory.
export pure directory(
  id: Str,
  at: Str,
  presence: model.Presence = .Present,
  owner: Str? = null,
  group_name: Str? = null,
  mode: Int? = null,
  parents: Bool = false,
  needs: List[Str] = [],
) -> Result[model.Resource, Error] {
  require_args("directory", id, needs)?
  ctx f"directory {id}" {
    check.path_ok("path", at)?
    check.not_root("path", at)?
    principals(owner, group_name)?
    modes(mode)?
  }

  let spec = model.DirectorySpec(path: at, presence:, owner:, group: group_name, mode:, parents:)
  Ok(model.Resource(id:, needs:, spec: model.Directory(spec)))
}

pure content_of(
  id: Str,
  presence: model.Presence,
  text: Str?,
  data: Bytes?,
  source: Path?,
  secret_env: Str?,
  template_file: Path?,
  template_json: Str?,
) -> Result[model.Content?, Error] {
  var chosen: List[model.Content] = []
  if text != null {
    chosen += [model.Inline(bytes.from_text(text))]
  }

  if data != null {
    chosen += [model.Inline(data)]
  }

  if source != null {
    chosen += [model.FromFile(source)]
  }

  if secret_env != null {
    check.environment_ok(secret_env)?
    chosen += [model.SecretEnv(secret_env)]
  }

  if template_file != null {
    let object_text = template_json ?? "{}"
    let _ = ctx f"file {id}: template_json" { json.decode(object_text)? }
    chosen += [model.Rendered(model.TemplateSource(file: template_file, json: object_text))]
  }

  if presence == .Absent {
    guard chosen.is_empty() else {
      fail f"file {id}: an absent file takes no content"
    }

    return Ok(null)
  }

  guard chosen.len() == 1 else {
    fail f"file {id}: give exactly one of text, data, source, secret_env and template_file"
  }

  Ok(chosen[0])
}

pure validator_ok(id: Str, validate: List[Str]) -> Result[Unit, Error] {
  if validate.is_empty() {
    return
  }

  ctx f"file {id}" {
    check.argv_ok("validate", validate)?
  }

  let placeholders = validate |> where { |word| word == "{}" } |> count()
  guard placeholders == 1 else {
    fail f"file {id}: validate needs exactly one `{{}}` word for the staged path"
  }
}

## Declare a regular file. Give exactly one of `text`, `data`, `source` (a
## local file that is streamed), `secret_env` (an environment variable on the
## controller whose value is never printed) and `template_file` (a Go
## text/template file rendered by the controller against the JSON object `template_json`). `validate` is an argv run on
## the staged file with its single `{}` word replaced by the staged path.
export pure file(
  id: Str,
  at: Str,
  presence: model.Presence = .Present,
  text: Str? = null,
  data: Bytes? = null,
  source: Path? = null,
  secret_env: Str? = null,
  template_file: Path? = null,
  template_json: Str? = null,
  owner: Str? = null,
  group_name: Str? = null,
  mode: Int? = null,
  validate: List[Str] = [],
  sensitive: Bool = false,
  needs: List[Str] = [],
) -> Result[model.Resource, Error] {
  require_args("file", id, needs)?
  ctx f"file {id}" {
    check.path_ok("path", at)?
    check.not_root("path", at)?
    principals(owner, group_name)?
    modes(mode)?
  }

  validator_ok(id, validate)?
  let content = content_of(id, presence, text, data, source, secret_env, template_file, template_json)?
  let marked = sensitive or secret_env != null
  let spec = model.FileSpec(path: at, presence:, content:, owner:, group: group_name, mode:, validate:, sensitive: marked)
  Ok(model.Resource(id:, needs:, spec: model.File(spec)))
}

## Declare a symbolic link. An existing link to another target is replaced
## only with `replace: true`; a file or directory at the path is never replaced.
export pure symlink(
  id: Str,
  at: Str,
  target: Str = "",
  presence: model.Presence = .Present,
  replace: Bool = false,
  needs: List[Str] = [],
) -> Result[model.Resource, Error] {
  require_args("symlink", id, needs)?
  ctx f"symlink {id}" {
    check.path_ok("path", at)?
    check.not_root("path", at)?
    if presence == .Present {
      guard target != "" and target.find("\0") == null else {
        fail "a present symlink needs a nonempty target without a NUL byte"
      }
    }
  }

  let replacement: model.Replacement = if replace { .ReplaceLink } else { .Keep }
  let spec = model.SymlinkSpec(path: at, presence:, target:, replacement:)
  Ok(model.Resource(id:, needs:, spec: model.Link(spec)))
}

pure constraint_of(version: Str) -> Result[model.Constraint, Error] {
  let table: List[Str] = [">=", "<=", "=", ">", "<"]
  for text in table {
    if version.starts_with(text) {
      let rest = version.byte_slice(text.byte_len())
      check.version_ok(rest)?
      let op: model.VersionOp = match text {
        ">=" => .Ge
        "<=" => .Le
        ">" => .Gt
        "<" => .Lt
        else => .Eq
      }
      return Ok(model.Constraint(op:, version: rest))
    }
  }

  check.version_ok(version)?
  Ok(model.Constraint(op: .Eq, version:))
}

## Declare an Alpine package through apk. `version` is an exact apk version or
## a bound such as `>=1.2.3-r0`, compared in apk's version ordering.
export pure package(
  id: Str,
  name: Str,
  presence: model.Presence = .Present,
  version: Str? = null,
  needs: List[Str] = [],
) -> Result[model.Resource, Error] {
  require_args("package", id, needs)?
  ctx f"package {id}" {
    check.package_ok(name)?
    guard presence == .Present or version == null else {
      fail "an absent package takes no version"
    }
  }

  let constraint = if version == null { null } else { ctx f"package {id}" { constraint_of(version)? } }
  let spec = model.PackageSpec(name:, presence:, constraint:)
  Ok(model.Resource(id:, needs:, spec: model.Package(spec)))
}

## Declare an explicit refresh of the apk index. It runs only at apply and is
## reported separately; plan and check never refresh.
export pure package_index(id: Str, needs: List[Str] = []) -> Result[model.Resource, Error] {
  require_args("package_index", id, needs)?
  let spec = model.PackageIndexSpec(note: "apk update")
  Ok(model.Resource(id:, needs:, spec: model.PackageIndex(spec)))
}

## Declare a group in the account database. A differing gid is a conflict,
## never changed.
export pure group_account(
  id: Str,
  name: Str,
  presence: model.Presence = .Present,
  gid: Int? = null,
  needs: List[Str] = [],
) -> Result[model.Resource, Error] {
  require_args("group", id, needs)?
  ctx f"group {id}" {
    check.account_ok("group name", name)?
    optional_id("gid", gid)?
  }

  let spec = model.GroupSpec(name:, presence:, gid:)
  Ok(model.Resource(id:, needs:, spec: model.GroupAccount(spec)))
}

## Declare a user. `groups` are supplementary memberships that must hold; extra
## memberships are left alone. A differing uid is a conflict, never changed.
## Removing a user never deletes its home directory or data.
export pure user_account(
  id: Str,
  name: Str,
  presence: model.Presence = .Present,
  uid: Int? = null,
  primary_group: Str? = null,
  groups: List[Str] = [],
  home: Str? = null,
  shell: Str? = null,
  system_account: Bool = false,
  needs: List[Str] = [],
) -> Result[model.Resource, Error] {
  require_args("user", id, needs)?
  ctx f"user {id}" {
    check.account_ok("user name", name)?
    optional_id("uid", uid)?
    optional_account("primary group", primary_group)?
    for member in groups {
      check.account_ok("group", member)?
    }

    optional_path("home", home)?
    optional_path("shell", shell)?
  }

  let spec = model.UserSpec(name:, presence:, uid:, group: primary_group, groups:, home:, shell:, system: system_account)
  Ok(model.Resource(id:, needs:, spec: model.UserAccount(spec)))
}

pure invocation_of(what: Str, argv: List[Str]?, shell: Str?) -> Result[model.Invocation, Error] {
  guard argv == null != (shell == null) else {
    fail f"{what}: give exactly one of argv and shell"
  }

  if argv != null {
    check.argv_ok(what, argv)?
    return Ok(model.Argv(argv))
  }

  check.shell_ok(what, shell ?? "")?
  Ok(model.Shell(shell ?? ""))
}

## Declare a command. Exactly one condition decides whether it runs:
## `creates` (skip when the path exists), `skip_if` or `only_if` (a read-only
## guard argv or `*_shell` string whose exit status decides), `run_on` (run
## only after a listed resource changed), or `always: true`. A command without
## one is refused; it would not be idempotent. `stdin_env` names a controller
## environment variable sent on stdin and never printed. A command that runs
## past `timeout_seconds` has an unknown outcome and is never retried.
export pure command(
  id: Str,
  argv: List[Str]? = null,
  shell: Str? = null,
  creates: Str? = null,
  skip_if: List[Str]? = null,
  skip_if_shell: Str? = null,
  only_if: List[Str]? = null,
  only_if_shell: Str? = null,
  run_on: List[Str] = [],
  always: Bool = false,
  stdin_env: Str? = null,
  accept: List[Int] = [0],
  timeout_seconds: Int = 600,
  needs: List[Str] = [],
) -> Result[model.Resource, Error] {
  require_args("command", id, needs)?
  let invocation = ctx f"command {id}" { invocation_of("command", argv, shell)? }
  var guards: List[model.Guard] = []
  if creates != null {
    ctx f"command {id}" { check.path_ok("creates", creates)? }
    guards += [model.Creates(creates)]
  }

  if skip_if != null or skip_if_shell != null {
    guards += [model.SkipIf(ctx f"command {id}" { invocation_of("skip_if", skip_if, skip_if_shell)? })]
  }

  if only_if != null or only_if_shell != null {
    guards += [model.OnlyIf(ctx f"command {id}" { invocation_of("only_if", only_if, only_if_shell)? })]
  }

  if ! run_on.is_empty() {
    ctx f"command {id}" { check.needs_ok(run_on)? }
    guards += [model.OnChange]
  }

  if always {
    guards += [model.Always]
  }

  guard guards.len() == 1 else {
    fail f"command {id}: give exactly one of creates, skip_if, only_if, run_on and always"
  }

  if stdin_env != null {
    ctx f"command {id}" { check.environment_ok(stdin_env)? }
  }

  guard ! accept.is_empty() else {
    fail f"command {id}: accept needs at least one exit code"
  }

  for code in accept {
    guard code >= 0 and code <= 255 else {
      fail f"command {id}: exit code out of range: {code}"
    }
  }

  guard timeout_seconds >= 1 and timeout_seconds <= 86400 else {
    fail f"command {id}: timeout_seconds must be 1..86400"
  }

  let spec = model.CommandSpec(invocation:, guard: guards[0], triggers: run_on, stdin_env:, accept:, timeout_ms: timeout_seconds * 1000)
  Ok(model.Resource(id:, needs:, spec: model.Exec(spec)))
}

## Declare an OpenRC service. `enabled` adds or removes it from `runlevel`;
## `running` starts or stops it. `reload_on` and `restart_on` name resources
## whose change reloads or restarts the service once per apply, however many
## of them changed; a restart supersedes a reload.
export pure service(
  id: Str,
  name: Str,
  enabled: Bool? = null,
  running: Bool? = null,
  runlevel: Str = "default",
  reload_on: List[Str] = [],
  restart_on: List[Str] = [],
  needs: List[Str] = [],
) -> Result[model.Resource, Error] {
  require_args("service", id, needs)?
  ctx f"service {id}" {
    check.service_ok(name)?
    check.service_ok(runlevel)?
    check.needs_ok(reload_on)?
    check.needs_ok(restart_on)?
  }

  guard enabled != null or running != null or ! reload_on.is_empty() or ! restart_on.is_empty() else {
    fail f"service {id}: declare enabled, running, or a trigger"
  }

  let spec = model.ServiceSpec(name:, adapter: .OpenRc, runlevel:, enabled:, running:, reload_on:, restart_on:)
  Ok(model.Resource(id:, needs:, spec: model.Service(spec)))
}

## Declare a Laputa xinit service. `running` starts or stops it; `reload_on`
## and `restart_on` name resources whose change reloads or restarts the service
## once per apply, however many of them changed; a restart supersedes a reload.
## xinit has no enable or disable, so `enabled` is refused.
export pure xinit_service(
  id: Str,
  name: Str,
  enabled: Bool? = null,
  running: Bool? = null,
  reload_on: List[Str] = [],
  restart_on: List[Str] = [],
  needs: List[Str] = [],
) -> Result[model.Resource, Error] {
  require_args("service", id, needs)?
  ctx f"service {id}" {
    check.service_ok(name)?
    check.needs_ok(reload_on)?
    check.needs_ok(restart_on)?
  }

  guard enabled == null else {
    fail f"service {id}: xinit has no enable or disable"
  }

  guard running != null or ! reload_on.is_empty() or ! restart_on.is_empty() else {
    fail f"service {id}: declare running, or a trigger"
  }

  let spec = model.ServiceSpec(name:, adapter: .Xinit, runlevel: "", enabled: null, running:, reload_on:, restart_on:)
  Ok(model.Resource(id:, needs:, spec: model.Service(spec)))
}
