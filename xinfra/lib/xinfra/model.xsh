##! Typed xinfra resources and their structural invariants.

## Desired presence of a managed object.
export enum State: Str { Present = "present", Absent = "absent" }

## Identity a resource runs as.
export enum Privilege: Str { AsUser = "user", AsRoot = "root" }

## Service action taken when a notifying resource changes.
export enum OnChange: Str { Reload = "reload", Restart = "restart" }

## Desired run state of an OpenRC service.
export enum ServiceState: Str { Started = "started", Stopped = "stopped" }

const DEFAULT_STATE: State = Present
const DEFAULT_SERVICE_STATE: ServiceState = Started
const DEFAULT_ON_CHANGE: OnChange = Restart
const DEFAULT_VARS: Map[Str, Str] = {}
const DEFAULT_ENV: Map[Str, Str] = {}

## A reference resolved to secret bytes only at apply time.
export enum SecretRef {
  FromEnv(Str),
  FromFile(Path),
}

## A local template artifact and the values it renders with.
export type Template = {path: Path, vars: Map[Str, Str] = DEFAULT_VARS}

## Exactly one content variant for a present file.
export enum FileSource {
  Source(Path),
  Content(Str),
  Secret(SecretRef),
  Templated(Template),
}

## A staged-file validator whose argv receives the staged path last.
export type Validation = {argv: List[Str]}

## A directory managed one level deep.
export type DirectorySpec = {
  id: Str,
  path: Path,
  state: State = DEFAULT_STATE,
  owner: Str? = null,
  group: Str? = null,
  mode: Int = 0o755,
  notify: List[Str] = [],
  requires: List[Str] = [],
  hosts: List[Str] = [],
  privilege: Privilege? = null,
}

## A regular file with exactly one content variant when present.
export type FileSpec = {
  id: Str,
  path: Path,
  source: FileSource? = null,
  owner: Str? = null,
  group: Str? = null,
  mode: Int = 0o644,
  validate: Validation? = null,
  state: State = DEFAULT_STATE,
  notify: List[Str] = [],
  requires: List[Str] = [],
  hosts: List[Str] = [],
  privilege: Privilege? = null,
}

## A symbolic link, never treated as a file or directory.
export type SymlinkSpec = {
  id: Str,
  path: Path,
  target: Path,
  state: State = DEFAULT_STATE,
  replace: Bool = false,
  notify: List[Str] = [],
  requires: List[Str] = [],
  hosts: List[Str] = [],
  privilege: Privilege? = null,
}

## An Alpine package.
export type PackageSpec = {
  id: Str,
  name: Str,
  state: State = DEFAULT_STATE,
  constraint: Str? = null,
  refresh_index: Bool = false,
  notify: List[Str] = [],
  requires: List[Str] = [],
  hosts: List[Str] = [],
  privilege: Privilege? = null,
}

## A local user account.
export type UserSpec = {
  id: Str,
  name: Str,
  state: State = DEFAULT_STATE,
  uid: Int? = null,
  gid: Int? = null,
  groups: List[Str] = [],
  home: Path? = null,
  shell: Path? = null,
  system: Bool = false,
  create_home: Bool = false,
  update: Bool = false,
  notify: List[Str] = [],
  requires: List[Str] = [],
  hosts: List[Str] = [],
  privilege: Privilege? = null,
}

## A local group.
export type GroupSpec = {
  id: Str,
  name: Str,
  state: State = DEFAULT_STATE,
  gid: Int? = null,
  system: Bool = false,
  notify: List[Str] = [],
  requires: List[Str] = [],
  hosts: List[Str] = [],
  privilege: Privilege? = null,
}

## A command guarded by creates, unless, or always_run.
export type CommandSpec = {
  id: Str,
  argv: List[Str]? = null,
  shell: Str? = null,
  creates: Path? = null,
  unless_argv: List[Str]? = null,
  env: Map[Str, Str] = DEFAULT_ENV,
  stdin_secret: SecretRef? = null,
  always_run: Bool = false,
  timeout: Duration? = null,
  notify: List[Str] = [],
  requires: List[Str] = [],
  hosts: List[Str] = [],
  privilege: Privilege? = null,
}

## An OpenRC service.
export type ServiceSpec = {
  id: Str,
  name: Str,
  state: ServiceState = DEFAULT_SERVICE_STATE,
  enabled: Bool? = null,
  on_change: OnChange = DEFAULT_ON_CHANGE,
  requires: List[Str] = [],
  hosts: List[Str] = [],
  privilege: Privilege? = null,
}

## The closed resource set.
export enum Resource {
  Directory(DirectorySpec),
  File(FileSpec),
  Symlink(SymlinkSpec),
  Package(PackageSpec),
  UserResource(UserSpec),
  GroupResource(GroupSpec),
  CommandResource(CommandSpec),
  ServiceResource(ServiceSpec),
}

## A structured validation failure shared by the model, loader, and planner.
export type Problem = {kind: Str, id: Str? = null, field: Str? = null, message: Str}

pure problem(kind: Str, message: Str, id: Str? = null, field: Str? = null) -> Problem {
  Problem(kind:, id:, field:, message:)
}

pure ascii_alnum(byte: Int) -> Bool {
  if byte >= 48 and byte <= 57 {
    return true
  }

  if byte >= 65 and byte <= 90 {
    return true
  }

  byte >= 97 and byte <= 122
}

pure valid_identifier(text: Str) -> Bool {
  if text.is_empty() {
    return false
  }

  let first = text.byte_at(0) ?? 0
  if ! (ascii_alnum(first) or first == 95) {
    return false
  }

  for index in range(1, text.byte_len()) {
    let byte = text.byte_at(index) ?? 0
    if ! (ascii_alnum(byte) or byte == 45 or byte == 46 or byte == 95) {
      return false
    }
  }

  true
}

pure valid_account(text: Str) -> Bool {
  valid_identifier(text)
}

pure valid_package_name(text: Str) -> Bool {
  if text.is_empty() {
    return false
  }

  let first = text.byte_at(0) ?? 0
  if ! (ascii_alnum(first) or first == 95) {
    return false
  }

  for index in range(1, text.byte_len()) {
    let byte = text.byte_at(index) ?? 0
    if ! (ascii_alnum(byte) or byte == 43 or byte == 45 or byte == 46 or byte == 64 or byte == 95) {
      return false
    }
  }

  true
}

pure has_nul(text: Str) -> Bool {
  for index in range(text.byte_len()) {
    if text.byte_at(index) == 0 {
      return true
    }
  }

  false
}

pure require_utf8(id: Str, field: Str, target: Path) -> Result[Unit, Problem] {
  match target.bytes().utf8() {
    Ok(_) => Ok(),
    Err(_) => Err(problem("non-utf8-path", "path is not UTF-8", id: id, field: field)),
  }
}

pure require_absolute(id: Str, field: Str, target: Path) -> Result[Unit, Problem] {
  if ! target.starts_with(p"/") {
    return Err(problem("invalid-field", "must be an absolute path", id: id, field: field))
  }

  for component in target.components() {
    if component.display() == ".." {
      return Err(problem("invalid-field", "must not contain '..'", id: id, field: field))
    }
  }

  Ok()
}

pure require_relative(id: Str, field: Str, target: Path) -> Result[Unit, Problem] {
  if target.starts_with(p"/") {
    return Err(problem("invalid-field", "must be relative to the deployment directory", id: id, field: field))
  }

  if target.components().is_empty() {
    return Err(problem("invalid-field", "must not be empty", id: id, field: field))
  }

  Ok()
}

pure check_path(id: Str, field: Str, target: Path, absolute: Bool) -> Result[Unit, Problem] {
  require_utf8(id, field, target)?
  if has_nul(target.display()) {
    return Err(problem("invalid-field", "must not contain NUL", id: id, field: field))
  }

  if absolute {
    return require_absolute(id, field, target)
  }

  require_relative(id, field, target)
}

pure check_text(id: Str, field: Str, text: Str) -> Result[Unit, Problem] {
  if has_nul(text) {
    return Err(problem("invalid-field", "must not contain NUL", id: id, field: field))
  }

  Ok()
}

pure check_mode(id: Str, field: Str, mode: Int) -> Result[Unit, Problem] {
  if mode < 0 or mode > 0o7777 {
    return Err(problem("invalid-field", "must be between 0 and 0o7777", id: id, field: field))
  }

  Ok()
}

pure check_account(id: Str, field: Str, name: Str?) -> Result[Unit, Problem] {
  if name == null {
    return Ok()
  }

  let actual = name ?? ""
  if ! valid_account(actual) {
    return Err(problem("invalid-field", f"invalid account name {actual}", id: id, field: field))
  }

  Ok()
}

pure check_identifiers(id: Str, field: Str, values: List[Str]) -> Result[Unit, Problem] {
  for value in values {
    if ! valid_identifier(value) {
      return Err(problem("invalid-field", f"invalid identifier {value}", id: id, field: field))
    }
  }

  Ok()
}

pure check_selectors(id: Str, values: List[Str]) -> Result[Unit, Problem] {
  check_identifiers(id, "hosts", values)
}

pure check_notify(id: Str, values: List[Str]) -> Result[Unit, Problem] {
  check_identifiers(id, "notify", values)
}

pure check_privilege(id: Str, owner: Str?, privilege: Privilege?) -> Result[Unit, Problem] {
  if owner == "root" and privilege != AsRoot {
    return Err(problem("invalid-field", "a root-owned path requires privilege=root", id: id, field: "privilege"))
  }

  Ok()
}

pure check_validation(id: Str, validation: Validation?) -> Result[Unit, Problem] {
  if validation == null {
    return Ok()
  }

  let spec = validation ?? Validation(argv: [])
  if spec.argv.is_empty() {
    return Err(problem("invalid-field", "must not be empty", id: id, field: "validate.argv"))
  }

  for argument in spec.argv {
    check_text(id, "validate.argv", argument)?
  }

  Ok()
}

pure check_template(id: Str, render_spec: Template) -> Result[Unit, Problem] {
  check_path(id, "template.path", render_spec.path, absolute: false)?
  for key in render_spec.vars.keys() {
    if key.is_empty() {
      return Err(problem("invalid-field", "variable names must not be empty", id: id, field: "template.vars"))
    }

    check_text(id, "template.vars", key)?
    check_text(id, "template.vars", render_spec.vars.get(key) ?? "")?
  }

  Ok()
}

pure check_file_source(id: Str, state: State, source: FileSource?) -> Result[Unit, Problem] {
  if state == Absent {
    if source != null {
      return Err(problem("invalid-field", "an absent file cannot declare a source variant", id: id, field: "source"))
    }

    return Ok()
  }

  if source == null {
    return Err(problem("invalid-field", "a present file requires exactly one source variant", id: id, field: "source"))
  }

  match source {
    Source(source_path) => check_path(id, "source", source_path, absolute: false),
    Content(text) => check_text(id, "content", text),
    Secret(reference) => check_secret(id, reference),
    Templated(render_spec) => check_template(id, render_spec),
  }
}

pure check_secret(id: Str, reference: SecretRef) -> Result[Unit, Problem] {
  match reference {
    FromEnv(name) => {
      if ! valid_identifier(name) {
        return Err(problem("invalid-field", f"invalid environment name {name}", id: id, field: "secret"))
      }

      Ok()
    }
    FromFile(secret_path) => check_path(id, "secret", secret_path, absolute: true),
  }
}

pure check_directory(spec: DirectorySpec) -> Result[Unit, Problem] {
  check_path(spec.id, "path", spec.path, absolute: true)?
  check_account(spec.id, "owner", spec.owner)?
  check_account(spec.id, "group", spec.group)?
  check_mode(spec.id, "mode", spec.mode)?
  check_selectors(spec.id, spec.hosts)?
  check_notify(spec.id, spec.notify)?
  check_identifiers(spec.id, "requires", spec.requires)?
  check_privilege(spec.id, spec.owner, spec.privilege)
}

pure check_file(spec: FileSpec) -> Result[Unit, Problem] {
  check_path(spec.id, "path", spec.path, absolute: true)?
  check_file_source(spec.id, spec.state, spec.source)?
  check_validation(spec.id, spec.validate)?
  check_account(spec.id, "owner", spec.owner)?
  check_account(spec.id, "group", spec.group)?
  check_mode(spec.id, "mode", spec.mode)?
  check_selectors(spec.id, spec.hosts)?
  check_notify(spec.id, spec.notify)?
  check_identifiers(spec.id, "requires", spec.requires)?
  check_privilege(spec.id, spec.owner, spec.privilege)
}

pure check_symlink(spec: SymlinkSpec) -> Result[Unit, Problem] {
  check_path(spec.id, "path", spec.path, absolute: true)?
  require_utf8(spec.id, "target", spec.target)?
  if has_nul(spec.target.display()) or spec.target.display().is_empty() {
    return Err(problem("invalid-field", "must be non-empty and NUL-free", id: spec.id, field: "target"))
  }

  check_selectors(spec.id, spec.hosts)?
  check_notify(spec.id, spec.notify)?
  check_identifiers(spec.id, "requires", spec.requires)
}

pure check_package(spec: PackageSpec) -> Result[Unit, Problem] {
  if ! valid_package_name(spec.name) {
    return Err(problem("invalid-field", f"invalid package name {spec.name}", id: spec.id, field: "name"))
  }

  if spec.state == Absent and spec.constraint != null {
    return Err(problem("invalid-field", "an absent package cannot be constrained", id: spec.id, field: "constraint"))
  }

  if spec.constraint != null {
    check_text(spec.id, "constraint", spec.constraint ?? "")?
  }

  check_selectors(spec.id, spec.hosts)?
  check_notify(spec.id, spec.notify)?
  check_identifiers(spec.id, "requires", spec.requires)
}

pure check_user(spec: UserSpec) -> Result[Unit, Problem] {
  if ! valid_account(spec.name) {
    return Err(problem("invalid-field", f"invalid user name {spec.name}", id: spec.id, field: "name"))
  }

  if spec.uid != null and (spec.uid ?? -1) < 0 {
    return Err(problem("invalid-field", "must not be negative", id: spec.id, field: "uid"))
  }

  if spec.gid != null and (spec.gid ?? -1) < 0 {
    return Err(problem("invalid-field", "must not be negative", id: spec.id, field: "gid"))
  }

  if spec.home != null {
    check_path(spec.id, "home", spec.home ?? p"/", absolute: true)?
  }

  if spec.shell != null {
    check_path(spec.id, "shell", spec.shell ?? p"/", absolute: true)?
  }

  check_identifiers(spec.id, "groups", spec.groups)?
  if spec.state == Absent and spec.update {
    return Err(problem("invalid-field", "an absent user cannot be updated", id: spec.id, field: "update"))
  }

  if spec.state == Absent and spec.create_home {
    return Err(problem("invalid-field", "an absent user cannot create a home", id: spec.id, field: "create_home"))
  }

  check_selectors(spec.id, spec.hosts)?
  check_notify(spec.id, spec.notify)?
  check_identifiers(spec.id, "requires", spec.requires)
}

pure check_group(spec: GroupSpec) -> Result[Unit, Problem] {
  if ! valid_account(spec.name) {
    return Err(problem("invalid-field", f"invalid group name {spec.name}", id: spec.id, field: "name"))
  }

  if spec.gid != null and (spec.gid ?? -1) < 0 {
    return Err(problem("invalid-field", "must not be negative", id: spec.id, field: "gid"))
  }

  check_selectors(spec.id, spec.hosts)?
  check_notify(spec.id, spec.notify)?
  check_identifiers(spec.id, "requires", spec.requires)
}

pure check_command(spec: CommandSpec) -> Result[Unit, Problem] {
  let has_argv = spec.argv != null
  let has_shell = spec.shell != null
  if has_argv == has_shell {
    return Err(problem("invalid-field", "exactly one of argv or shell must be declared", id: spec.id, field: "argv"))
  }

  if spec.argv != null {
    let argv = spec.argv ?? []
    if argv.is_empty() or argv[0].is_empty() {
      return Err(problem("invalid-field", "must start with a program", id: spec.id, field: "argv"))
    }

    for argument in argv {
      check_text(spec.id, "argv", argument)?
    }
  }

  if spec.shell != null {
    check_text(spec.id, "shell", spec.shell ?? "")?
    if (spec.shell ?? "").is_empty() {
      return Err(problem("invalid-field", "must not be empty", id: spec.id, field: "shell"))
    }
  }

  if spec.creates != null {
    check_path(spec.id, "creates", spec.creates ?? p"/", absolute: true)?
  }

  if spec.unless_argv != null {
    let unless_argv = spec.unless_argv ?? []
    if unless_argv.is_empty() or unless_argv[0].is_empty() {
      return Err(problem("invalid-field", "must start with a program", id: spec.id, field: "unless"))
    }

    for argument in unless_argv {
      check_text(spec.id, "unless", argument)?
    }
  }

  if spec.always_run and (spec.creates != null or spec.unless_argv != null) {
    return Err(problem("invalid-field", "always_run cannot be combined with creates or unless", id: spec.id, field: "always_run"))
  }

  if ! spec.always_run and spec.creates == null and spec.unless_argv == null {
    return Err(problem("invalid-field", "a command needs a guard or always_run=true", id: spec.id, field: "always_run"))
  }

  for key in spec.env.keys() {
    if key.is_empty() {
      return Err(problem("invalid-field", "environment names must not be empty", id: spec.id, field: "env"))
    }

    check_text(spec.id, "env", key)?
    check_text(spec.id, "env", spec.env.get(key) ?? "")?
  }

  if spec.stdin_secret != null {
    check_secret(spec.id, spec.stdin_secret ?? FromEnv(""))
  }

  if spec.timeout != null and (spec.timeout ?? 0s) <= 0s {
    return Err(problem("invalid-field", "must be positive", id: spec.id, field: "timeout"))
  }

  check_selectors(spec.id, spec.hosts)?
  check_notify(spec.id, spec.notify)?
  check_identifiers(spec.id, "requires", spec.requires)
}

pure check_service(spec: ServiceSpec) -> Result[Unit, Problem] {
  if ! valid_identifier(spec.name) {
    return Err(problem("invalid-field", f"invalid service name {spec.name}", id: spec.id, field: "name"))
  }

  check_selectors(spec.id, spec.hosts)?
  check_identifiers(spec.id, "requires", spec.requires)
}

pure check_id(resource: Resource) -> Result[Unit, Problem] {
  let id = identity(resource)
  if id.is_empty() {
    return Err(problem("empty-id", "resource id must not be empty"))
  }

  if ! valid_identifier(id) {
    return Err(problem("invalid-id", f"invalid resource id {id}", id: id))
  }

  Ok()
}

## Returns the stable explicit identifier of a resource.
export pure identity(resource: Resource) -> Str {
  match resource {
    Directory(spec) => spec.id,
    File(spec) => spec.id,
    Symlink(spec) => spec.id,
    Package(spec) => spec.id,
    UserResource(spec) => spec.id,
    GroupResource(spec) => spec.id,
    CommandResource(spec) => spec.id,
    ServiceResource(spec) => spec.id,
  }
}

## Returns the dependency identifiers declared by a resource.
export pure requirements(resource: Resource) -> List[Str] {
  match resource {
    Directory(spec) => spec.requires,
    File(spec) => spec.requires,
    Symlink(spec) => spec.requires,
    Package(spec) => spec.requires,
    UserResource(spec) => spec.requires,
    GroupResource(spec) => spec.requires,
    CommandResource(spec) => spec.requires,
    ServiceResource(spec) => spec.requires,
  }
}

## Returns the host selectors declared by a resource; empty selects every host.
export pure host_selectors(resource: Resource) -> List[Str] {
  match resource {
    Directory(spec) => spec.hosts,
    File(spec) => spec.hosts,
    Symlink(spec) => spec.hosts,
    Package(spec) => spec.hosts,
    UserResource(spec) => spec.hosts,
    GroupResource(spec) => spec.hosts,
    CommandResource(spec) => spec.hosts,
    ServiceResource(spec) => spec.hosts,
  }
}

## Returns the service identifiers notified by a resource.
export pure notifications(resource: Resource) -> List[Str] {
  match resource {
    Directory(spec) => spec.notify,
    File(spec) => spec.notify,
    Symlink(spec) => spec.notify,
    Package(spec) => spec.notify,
    UserResource(spec) => spec.notify,
    GroupResource(spec) => spec.notify,
    CommandResource(spec) => spec.notify,
    ServiceResource(_) => [],
  }
}

## Returns whether a resource manages a service.
export pure is_service(resource: Resource) -> Bool {
  match resource {
    ServiceResource(_) => true,
    _ => false,
  }
}

## Returns the privilege a resource runs as, applying the per-kind default.
export pure privilege(resource: Resource) -> Privilege {
  let declared = match resource {
    Directory(spec) => spec.privilege,
    File(spec) => spec.privilege,
    Symlink(spec) => spec.privilege,
    Package(spec) => spec.privilege,
    UserResource(spec) => spec.privilege,
    GroupResource(spec) => spec.privilege,
    CommandResource(spec) => spec.privilege,
    ServiceResource(spec) => spec.privilege,
  }

  if declared != null {
    return declared ?? AsUser
  }

  match resource {
    Package(_) => AsRoot,
    UserResource(_) => AsRoot,
    GroupResource(_) => AsRoot,
    ServiceResource(_) => AsRoot,
    _ => AsUser,
  }
}

## Returns whether a resource applies to a host with the given name and groups.
export pure applies_to(resource: Resource, host: Str, groups: List[Str]) -> Bool {
  let selectors = host_selectors(resource)
  if selectors.is_empty() {
    return true
  }

  for selector in selectors {
    if selector == host or selector in groups {
      return true
    }
  }

  false
}

## Checks one resource's structure without touching a host.
export pure validate(resource: Resource) -> Result[Unit, Problem] {
  check_id(resource)?
  match resource {
    Directory(spec) => check_directory(spec),
    File(spec) => check_file(spec),
    Symlink(spec) => check_symlink(spec),
    Package(spec) => check_package(spec),
    UserResource(spec) => check_user(spec),
    GroupResource(spec) => check_group(spec),
    CommandResource(spec) => check_command(spec),
    ServiceResource(spec) => check_service(spec),
  }
}

## Checks every resource's structure, stopping at the first failure.
export pure validate_all(resources: List[Resource]) -> Result[Unit, Problem] {
  for resource in resources {
    validate(resource)?
  }

  Ok()
}
