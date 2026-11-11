##! Typed descriptions of hosts and desired resources. Declaring a resource
##! builds a value and touches nothing.

## Whether a resource must exist or must be absent.
export enum Presence: Str { Present = "present", Absent = "absent" }

## How mutations gain the authority to run: as the login user, as a login that
## already is root, or through noninteractive `doas`.
export enum Privilege: Str { Plain = "plain", Root = "root", Doas = "doas" }

## How a host is reached. `Local` runs the same scripts through a local
## `/bin/sh` and exists for tests and development.
export enum TransportKind: Str { Ssh = "ssh", Local = "local" }

## One managed machine.
export type Host = {
  name: Str,
  transport: TransportKind,
  address: Str,
  port: Int,
  user: Str,
  key: Path?,
  host_key: Str?,
  privilege: Privilege,
  groups: List[Str],
  vars: Map[Str, Any],
  timeout_ms: Int,
  transfer_timeout_ms: Int,
  escalate_reads: Bool,
}

## A local Go text/template file and the JSON object it is rendered against.
## The controller renders it when the content is measured or sent.
export type TemplateSource = {file: Path, json: Str}

## Where the bytes of a managed file come from. Inline and secret bytes are held
## by the controller; a local file streams without being loaded; a template is
## rendered by the controller.
export enum Content { Inline(Bytes), FromFile(Path), SecretEnv(Str), Rendered(TemplateSource) }

## A directory, optionally with ownership and mode.
export type DirectorySpec = {
  path: Str,
  presence: Presence,
  owner: Str?,
  group: Str?,
  mode: Int?,
  parents: Bool,
}

## A regular file replaced through a private staging file in its directory.
export type FileSpec = {
  path: Str,
  presence: Presence,
  content: Content?,
  owner: Str?,
  group: Str?,
  mode: Int?,
  validate: List[Str],
  sensitive: Bool,
}

## Whether an existing symlink at the path may be replaced by a different one.
export enum Replacement: Str { Keep = "keep", ReplaceLink = "replace-link" }

## A symbolic link and its target.
export type SymlinkSpec = {
  path: Str,
  presence: Presence,
  target: Str,
  replacement: Replacement,
}

## A comparison between an installed apk version and a wanted one.
export enum VersionOp: Str { Eq = "=", Ge = ">=", Le = "<=", Gt = ">", Lt = "<" }

## A version bound in apk's version ordering.
export type Constraint = {op: VersionOp, version: Str}

## An Alpine package present or absent, optionally within a version bound.
export type PackageSpec = {name: Str, presence: Presence, constraint: Constraint?}

## An explicit, apply-only refresh of the package index.
export type PackageIndexSpec = {note: Str}

## A group of the host's account database.
export type GroupSpec = {name: Str, presence: Presence, gid: Int?}

## A user of the host's account database.
export type UserSpec = {
  name: Str,
  presence: Presence,
  uid: Int?,
  group: Str?,
  groups: List[Str],
  home: Str?,
  shell: Str?,
  system: Bool,
}

## A command that is either argv or an explicit shell string.
export enum Invocation { Argv(List[Str]), Shell(Str) }

## When a command runs: always, unless a path exists, when a read-only guard
## succeeds or fails, or only after a listed resource changed.
export enum Guard { Always, Creates(Str), SkipIf(Invocation), OnlyIf(Invocation), OnChange }

## A command and its idempotence contract.
export type CommandSpec = {
  invocation: Invocation,
  guard: Guard,
  triggers: List[Str],
  stdin_env: Str?,
  accept: List[Int],
  timeout_ms: Int,
}

## The service managers xsh-infra can drive.
export enum ServiceAdapter: Str { OpenRc = "openrc" }

## A service, its boot enablement and running state, and the resources whose
## change reloads or restarts it.
export type ServiceSpec = {
  name: Str,
  adapter: ServiceAdapter,
  runlevel: Str,
  enabled: Bool?,
  running: Bool?,
  reload_on: List[Str],
  restart_on: List[Str],
}

## The closed set of resource kinds.
export enum Spec {
  Directory(DirectorySpec),
  File(FileSpec),
  Link(SymlinkSpec),
  Package(PackageSpec),
  PackageIndex(PackageIndexSpec),
  GroupAccount(GroupSpec),
  UserAccount(UserSpec),
  Exec(CommandSpec),
  Service(ServiceSpec),
}

## A resource with a stable explicit identifier and the identifiers it needs.
export type Resource = {id: Str, needs: List[Str], spec: Spec}

## The name of a resource kind as reports spell it.
export pure kind(spec: Spec) -> Str {
  match spec {
    Directory(_) => "directory"
    File(_) => "file"
    Link(_) => "symlink"
    Package(_) => "package"
    PackageIndex(_) => "package-index"
    GroupAccount(_) => "group"
    UserAccount(_) => "user"
    Exec(_) => "command"
    Service(_) => "service"
  }
}

## Identifiers whose change triggers this resource, beyond `needs`.
export pure triggers(spec: Spec) -> List[Str] {
  match spec {
    Exec(command) => command.triggers
    Service(service) => service.reload_on + service.restart_on
    else => []
  }
}

## Every identifier that must be settled before this resource runs.
export pure dependencies(resource: Resource) -> List[Str] {
  resource.needs + triggers(resource.spec)
}

