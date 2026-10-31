##! Observed facts and the pure planner that turns them into ordered actions.

use xinfra.inventory
use xinfra.model
use xinfra.validate

## Observed filesystem metadata for a managed path.
export type PathFacts = {
  kind: Str,
  mode: Int,
  owner: Str? = null,
  group: Str? = null,
  digest: Str? = null,
  target: Path? = null,
  empty: Bool = true,
}

## Observed package state; satisfies is the constraint comparison result.
export type PackageFacts = {version: Str? = null, satisfies: Bool? = null}

## Observed user account fields.
export type UserFacts = {
  uid: Int,
  gid: Int,
  groups: List[Str] = [],
  home: Path? = null,
  shell: Path? = null,
}

## Observed group fields.
export type GroupFacts = {gid: Int}

## Observed guard results for one command.
export type CommandFacts = {creates_present: Bool? = null, unless_satisfied: Bool? = null}

## Observed service state.
export type ServiceFacts = {started: Bool, enabled: Bool? = null}

## The fact shape a resource can observe.
export enum Observed {
  Absent,
  Existing(PathFacts),
  Installed(PackageFacts),
  Account(UserFacts),
  Role(GroupFacts),
  Invocation(CommandFacts),
  Running(ServiceFacts),
  Unknown,
}

## Facts gathered for one host, keyed by resource id.
export type HostFacts = {name: Str, observed: Map[Str, Observed]}

## Facts gathered for every planned host.
export type Facts = {hosts: List[HostFacts]}

## What applying a resource would do.
export enum Operation: Str {
  EnsureDirectory = "ensure_directory",
  RemoveDirectory = "remove_directory",
  EnsureFile = "ensure_file",
  RemoveFile = "remove_file",
  EnsureSymlink = "ensure_symlink",
  RemoveSymlink = "remove_symlink",
  EnsurePackage = "ensure_package",
  RemovePackage = "remove_package",
  EnsureUser = "ensure_user",
  RemoveUser = "remove_user",
  EnsureGroup = "ensure_group",
  RemoveGroup = "remove_group",
  RunCommand = "run_command",
  StartService = "start_service",
  StopService = "stop_service",
  ConfigureService = "configure_service",
}

## What the pure comparison predicts for one action.
export enum Prediction: Str {
  Unchanged = "unchanged",
  Changed = "changed",
  Blocked = "blocked",
  Undetermined = "unknown",
}

## The pure comparison result for one resource on one host.
export type Assessment = {
  prediction: Prediction,
  operation: Operation,
  cause: Str? = null,
}

## One intended action in resource topological order.
export type Action = {
  id: Str,
  host: Str,
  resource: model.Resource,
  operation: Operation,
  prediction: Prediction,
  cause: Str? = null,
  source: validate.PreparedSource? = null,
  expected_digest: Str? = null,
}

## The result of comparing post-apply observation with the desired state.
export type Verification = {ok: Bool, cause: Str? = null}

pure matching(declared: Str?, observed: Str?) -> Bool {
  if declared == null {
    return true
  }

  observed != null and observed == declared
}

pure contains_all(actual: List[Str], expected: List[Str]) -> Bool {
  for value in expected {
    if ! (value in actual) {
      return false
    }
  }

  true
}

pure path_matches(facts: PathFacts, spec: model.DirectorySpec) -> Bool {
  facts.mode == spec.mode and matching(spec.owner, facts.owner) and matching(spec.group, facts.group)
}

pure file_matches(facts: PathFacts, spec: model.FileSpec, digest: Str?) -> Bool {
  if digest != null and facts.digest != digest {
    return false
  }

  facts.mode == spec.mode and matching(spec.owner, facts.owner) and matching(spec.group, facts.group)
}

pure directory_assessment(spec: model.DirectorySpec, observed: Observed) -> Assessment {
  match observed {
    Absent => {
      if spec.state == model.Absent {
        return Assessment(prediction: Unchanged, operation: RemoveDirectory)
      }

      Assessment(prediction: Changed, operation: EnsureDirectory)
    }
    Existing(facts) => {
      if spec.state == model.Absent {
        if facts.kind != "dir" {
          return Assessment(
            prediction: Blocked,
            operation: RemoveDirectory,
            cause: f"{spec.path.display()} is a {facts.kind}, not a directory",
          )
        }

        if ! facts.empty {
          return Assessment(
            prediction: Blocked,
            operation: RemoveDirectory,
            cause: f"{spec.path.display()} is not empty; directory absence is one level",
          )
        }

        return Assessment(prediction: Changed, operation: RemoveDirectory)
      }

      if facts.kind != "dir" {
        return Assessment(
          prediction: Blocked,
          operation: EnsureDirectory,
          cause: f"{spec.path.display()} is a {facts.kind}, not a directory",
        )
      }

      if path_matches(facts, spec) {
        return Assessment(prediction: Unchanged, operation: EnsureDirectory)
      }

      Assessment(prediction: Changed, operation: EnsureDirectory)
    }
    Unknown => Assessment(
      prediction: Undetermined,
      operation: if spec.state == model.Absent { RemoveDirectory } else { EnsureDirectory },
      cause: "no observed state for the directory",
    ),
    _ => Assessment(prediction: Blocked, operation: EnsureDirectory, cause: "observed facts do not describe a path"),
  }
}

pure file_assessment(
  spec: model.FileSpec,
  source: validate.PreparedSource?,
  observed: Observed,
) -> Assessment {
  let digest = if source == null { null } else { validate.digest(source) }
  let secret = if source == null {
    false
  } else {
    validate.secret_reference(source) != null
  }
  match observed {
    Absent => {
      if spec.state == model.Absent {
        return Assessment(prediction: Unchanged, operation: RemoveFile)
      }

      Assessment(prediction: Changed, operation: EnsureFile)
    }
    Existing(facts) => {
      if spec.state == model.Absent {
        if facts.kind != "file" {
          return Assessment(
            prediction: Blocked,
            operation: RemoveFile,
            cause: f"{spec.path.display()} is a {facts.kind}, not a file",
          )
        }

        return Assessment(prediction: Changed, operation: RemoveFile)
      }

      if facts.kind != "file" {
        return Assessment(
          prediction: Blocked,
          operation: EnsureFile,
          cause: f"{spec.path.display()} is a {facts.kind}, not a file",
        )
      }

      if secret {
        return Assessment(
          prediction: Undetermined,
          operation: EnsureFile,
          cause: "secret content is resolved only at apply time",
        )
      }

      if file_matches(facts, spec, digest) {
        return Assessment(prediction: Unchanged, operation: EnsureFile)
      }

      Assessment(prediction: Changed, operation: EnsureFile)
    }
    Unknown => Assessment(
      prediction: Undetermined,
      operation: if spec.state == model.Absent { RemoveFile } else { EnsureFile },
      cause: "no observed state for the file",
    ),
    _ => Assessment(prediction: Blocked, operation: EnsureFile, cause: "observed facts do not describe a path"),
  }
}

pure symlink_assessment(spec: model.SymlinkSpec, observed: Observed) -> Assessment {
  match observed {
    Absent => {
      if spec.state == model.Absent {
        return Assessment(prediction: Unchanged, operation: RemoveSymlink)
      }

      Assessment(prediction: Changed, operation: EnsureSymlink)
    }
    Existing(facts) => {
      if spec.state == model.Absent {
        if facts.kind != "symlink" {
          return Assessment(
            prediction: Blocked,
            operation: RemoveSymlink,
            cause: f"{spec.path.display()} is a {facts.kind}, not a symbolic link",
          )
        }

        return Assessment(prediction: Changed, operation: RemoveSymlink)
      }

      if facts.kind != "symlink" {
        if spec.replace {
          return Assessment(prediction: Changed, operation: EnsureSymlink)
        }

        return Assessment(
          prediction: Blocked,
          operation: EnsureSymlink,
          cause: f"{spec.path.display()} is a {facts.kind}; replace is false",
        )
      }

      if facts.target == spec.target {
        return Assessment(prediction: Unchanged, operation: EnsureSymlink)
      }

      if spec.replace {
        return Assessment(prediction: Changed, operation: EnsureSymlink)
      }

      Assessment(
        prediction: Blocked,
        operation: EnsureSymlink,
        cause: f"{spec.path.display()} points elsewhere and replace is false",
      )
    }
    Unknown => Assessment(
      prediction: Undetermined,
      operation: if spec.state == model.Absent { RemoveSymlink } else { EnsureSymlink },
      cause: "no observed state for the symbolic link",
    ),
    _ => Assessment(
      prediction: Blocked,
      operation: EnsureSymlink,
      cause: "observed facts do not describe a symbolic link",
    ),
  }
}

pure package_assessment(spec: model.PackageSpec, observed: Observed) -> Assessment {
  match observed {
    Absent => {
      if spec.state == model.Absent {
        return Assessment(prediction: Unchanged, operation: RemovePackage)
      }

      Assessment(prediction: Changed, operation: EnsurePackage)
    }
    Installed(facts) => {
      if spec.state == model.Absent {
        return Assessment(prediction: Changed, operation: RemovePackage)
      }

      if spec.constraint == null {
        return Assessment(prediction: Unchanged, operation: EnsurePackage)
      }

      match facts.satisfies {
        true => Assessment(prediction: Unchanged, operation: EnsurePackage),
        false => Assessment(prediction: Changed, operation: EnsurePackage),
        _ => Assessment(
          prediction: Undetermined,
          operation: EnsurePackage,
          cause: "package constraint comparison is unavailable",
        ),
      }
    }
    Unknown => Assessment(
      prediction: Undetermined,
      operation: if spec.state == model.Absent { RemovePackage } else { EnsurePackage },
      cause: "no observed state for the package",
    ),
    _ => Assessment(prediction: Blocked, operation: EnsurePackage, cause: "observed facts do not describe a package"),
  }
}

pure user_assessment(spec: model.UserSpec, observed: Observed) -> Assessment {
  match observed {
    Absent => {
      if spec.state == model.Absent {
        return Assessment(prediction: Unchanged, operation: RemoveUser)
      }

      Assessment(prediction: Changed, operation: EnsureUser)
    }
    Account(facts) => {
      if spec.state == model.Absent {
        return Assessment(prediction: Changed, operation: RemoveUser)
      }

      if spec.uid != null and facts.uid != spec.uid {
        return Assessment(
          prediction: Blocked,
          operation: EnsureUser,
          cause: "update never changes a uid",
        )
      }

      if spec.gid != null and facts.gid != spec.gid {
        return Assessment(
          prediction: Blocked,
          operation: EnsureUser,
          cause: "update never changes a gid",
        )
      }

      if ! contains_all(facts.groups, spec.groups) {
        if ! spec.update {
          return Assessment(
            prediction: Blocked,
            operation: EnsureUser,
            cause: "existing group membership differs and update is false",
          )
        }

        return Assessment(prediction: Changed, operation: EnsureUser)
      }

      if spec.home != null and facts.home != spec.home {
        if ! spec.update {
          return Assessment(prediction: Blocked, operation: EnsureUser, cause: "existing home differs and update is false")
        }

        return Assessment(prediction: Changed, operation: EnsureUser)
      }

      if spec.shell != null and facts.shell != spec.shell {
        if ! spec.update {
          return Assessment(prediction: Blocked, operation: EnsureUser, cause: "existing shell differs and update is false")
        }

        return Assessment(prediction: Changed, operation: EnsureUser)
      }

      Assessment(prediction: Unchanged, operation: EnsureUser)
    }
    Unknown => Assessment(
      prediction: Undetermined,
      operation: if spec.state == model.Absent { RemoveUser } else { EnsureUser },
      cause: "no observed state for the user",
    ),
    _ => Assessment(prediction: Blocked, operation: EnsureUser, cause: "observed facts do not describe a user"),
  }
}

pure group_assessment(spec: model.GroupSpec, observed: Observed) -> Assessment {
  match observed {
    Absent => {
      if spec.state == model.Absent {
        return Assessment(prediction: Unchanged, operation: RemoveGroup)
      }

      Assessment(prediction: Changed, operation: EnsureGroup)
    }
    Role(facts) => {
      if spec.state == model.Absent {
        return Assessment(prediction: Changed, operation: RemoveGroup)
      }

      if spec.gid != null and facts.gid != spec.gid {
        return Assessment(
          prediction: Blocked,
          operation: EnsureGroup,
          cause: "an existing group has another gid",
        )
      }

      Assessment(prediction: Unchanged, operation: EnsureGroup)
    }
    Unknown => Assessment(
      prediction: Undetermined,
      operation: if spec.state == model.Absent { RemoveGroup } else { EnsureGroup },
      cause: "no observed state for the group",
    ),
    _ => Assessment(prediction: Blocked, operation: EnsureGroup, cause: "observed facts do not describe a group"),
  }
}

pure command_assessment(spec: model.CommandSpec, observed: Observed) -> Assessment {
  let operation = RunCommand
  if spec.always_run {
    return Assessment(prediction: Changed, operation: operation)
  }

  match observed {
    Invocation(facts) => {
      var skip = false
      var unknown = false
      if spec.creates != null {
        match facts.creates_present {
          true => skip = true,
          false => {}
          null => unknown = true,
        }
      }

      if ! skip and spec.unless_argv != null {
        match facts.unless_satisfied {
          true => skip = true,
          false => {}
          null => unknown = true,
        }
      }

      if skip {
        return Assessment(prediction: Unchanged, operation: operation)
      }

      if unknown {
        return Assessment(
          prediction: Undetermined,
          operation: operation,
          cause: "a command guard has no observed result",
        )
      }

      Assessment(prediction: Changed, operation: operation)
    }
    _ => Assessment(
      prediction: Undetermined,
      operation: operation,
      cause: "no observed guard result for the command",
    ),
  }
}

pure service_assessment(spec: model.ServiceSpec, observed: Observed) -> Assessment {
  match observed {
    Running(facts) => {
      let running = facts.started
      let wants_running = spec.state == model.Started
      var operation = ConfigureService
      if running and ! wants_running {
        operation = StopService
      }

      if ! running and wants_running {
        operation = StartService
      }

      if spec.enabled == null {
        if running == wants_running {
          return Assessment(prediction: Unchanged, operation: operation)
        }

        return Assessment(prediction: Changed, operation: operation)
      }

      if facts.enabled == null {
        return Assessment(
          prediction: Undetermined,
          operation: operation,
          cause: "service enablement is unavailable",
        )
      }

      if running == wants_running and facts.enabled == spec.enabled {
        return Assessment(prediction: Unchanged, operation: operation)
      }

      Assessment(prediction: Changed, operation: operation)
    }
    _ => Assessment(
      prediction: Undetermined,
      operation: ConfigureService,
      cause: "no observed service state",
    ),
  }
}

pure requirement_prediction(predictions: Map[Str, Prediction], id: Str) -> Prediction? {
  match predictions.get(id) {
    Ok(value) => value,
    Err(_) => null,
  }
}

pure prepared_source(deployment: validate.Deployment, id: Str) -> validate.PreparedSource? {
  match deployment.sources.get(id) {
    Ok(value) => value,
    Err(_) => null,
  }
}

## Compares one resource with observed facts without touching a host.
export pure assess(
  resource: model.Resource,
  source: validate.PreparedSource?,
  observed: Observed,
) -> Assessment {
  match resource {
    model.Directory(spec) => directory_assessment(spec, observed),
    model.File(spec) => file_assessment(spec, source, observed),
    model.Symlink(spec) => symlink_assessment(spec, observed),
    model.Package(spec) => package_assessment(spec, observed),
    model.UserResource(spec) => user_assessment(spec, observed),
    model.GroupResource(spec) => group_assessment(spec, observed),
    model.CommandResource(spec) => command_assessment(spec, observed),
    model.ServiceResource(spec) => service_assessment(spec, observed),
  }
}

## Compares a post-apply observation with the desired state.
export pure verify(
  resource: model.Resource,
  source: validate.PreparedSource?,
  observed: Observed,
) -> Verification {
  let assessment = assess(resource, source, observed)
  if assessment.prediction == Unchanged {
    return Verification(ok: true)
  }

  Verification(ok: false, cause: assessment.cause ?? f"observed state is not the intended state")
}

## Returns the facts gathered for one host and resource id, defaulting to unknown.
export pure observed(facts: Facts, host: Str, id: Str) -> Observed {
  for entry in facts.hosts {
    if entry.name == host {
      return entry.observed.get(id) ?? Unknown
    }
  }

  Unknown
}

## Computes the ordered actions for selected hosts without calling a transport.
export pure plan(
  deployment: validate.Deployment,
  inventory: inventory.Inventory,
  facts: Facts,
) -> List[Action] {
  var actions: List[Action] = []
  var predictions: Map[Str, Map[Str, Prediction]] = map.empty()
  for host in inventory.hosts {
    predictions = predictions.set(host.name, map.empty())
  }

  for resource in deployment.resources {
    let id = model.identity(resource)
    let source = prepared_source(deployment, id)
    let digest = if source == null { null } else { validate.digest(source) }
    for host in inventory.hosts {
      if ! model.applies_to(resource, host.name, host.groups) {
        continue
      }

      let observed_facts = observed(facts, host.name, id)
      var assessment = assess(resource, source, observed_facts)
      var missing: Str? = null
      var prerequisite: Str? = null
      for requirement in model.requirements(resource) {
        let host_predictions: Map[Str, Prediction] = predictions.get(host.name) ?? map.empty()
        let previous = requirement_prediction(host_predictions, requirement)
        if previous == null {
          missing = requirement
        } else if previous == Blocked or previous == Undetermined {
          prerequisite = requirement
        }
      }

      if missing != null {
        assessment = Assessment(
          prediction: Blocked,
          operation: assessment.operation,
          cause: f"prerequisite {missing ?? ""} is not selected for {host.name}",
        )
      } else if prerequisite != null {
        assessment = Assessment(
          prediction: Blocked,
          operation: assessment.operation,
          cause: f"prerequisite {prerequisite ?? ""} is blocked or unknown on {host.name}",
        )
      }

      actions += [
        Action(
          id: id,
          host: host.name,
          resource: resource,
          operation: assessment.operation,
          prediction: assessment.prediction,
          cause: assessment.cause,
          source: source,
          expected_digest: digest,
        ),
      ]
      let host_predictions: Map[Str, Prediction] = predictions.get(host.name) ?? map.empty()
      predictions = predictions.set(host.name, host_predictions.set(id, assessment.prediction))
    }
  }

  actions
}

## Builds an empty fact set for a host list.
export pure empty_facts(hosts: List[Str]) -> Facts {
  var entries: List[HostFacts] = []
  for host in hosts {
    entries += [HostFacts(name: host, observed: map.empty())]
  }

  Facts(hosts: entries)
}
