##! xinfra command line parsing, selection, apply policy, and reporting.

use xinfra.driver
use xinfra.host
use xinfra.inventory
use xinfra.model
use xinfra.notify
use xinfra.outcome
use xinfra.plan
use xinfra.redact
use xinfra.report
use xinfra.secret
use xinfra.transport
use xinfra.resources.dir
use xinfra.resources.file
use xinfra.resources.symlink
use xinfra.validate
use xinfra.version

## The subcommand selected on the command line.
export enum Subcommand: Str {
  Doctor = "doctor",
  Plan = "plan",
  Apply = "apply",
  Check = "check",
  Unlock = "unlock",
}

## What apply does after the first failed host action.
export enum OnError: Str {
  Isolate = "isolate",
  Abort = "abort",
  Continue = "continue",
}

## Parsed command-line options with their defaults.
export type Options = {
  command: Subcommand,
  inventory: Path? = null,
  deploy: Path? = null,
  limit: List[Str] = [],
  exclude: List[Str] = [],
  jobs: Int = 8,
  on_error: OnError = Isolate,
  style: report.Style = report.Human,
  save_plan: Path? = null,
  plan: Path? = null,
  host: Str? = null,
  force: Bool = false,
  help: Bool = false,
}

## One command's stdout, stderr, and exit code.
export type Execution = {exit: Int, stdout: Str, stderr: Str}

## Inputs and actions computed for one invocation.
export type Computed = {
  inventory: inventory.Inventory,
  deployment: validate.Deployment,
  deployment_file: Path,
  inventory_file: Path,
  facts: plan.Facts,
  actions: List[plan.Action],
}

## One applied action with its measured duration.
export type Applied = {result: host.ApplyResult, duration_ms: Int}

## A long option split into its name and optional inline value.
export type SplitOption = {name: Str, value: Str?}

## One planned action in a saved plan.
export type PlanAction = {id: Str, host: Str, operation: Str}

## One prepared source digest in a saved plan.
export type PlanSource = {id: Str, digest: Str}

## One observed precondition in a saved plan.
export type PlanObservation = {host: Str, resource: Str, fact: Str}

## The version-1 saved-plan artifact.
export type PlanArtifact = {
  schema_version: Int,
  kind: Str,
  run_id: Str,
  deployment: Str,
  inventory: Str,
  deployment_digest: Str,
  inventory_digest: Str,
  version: Str,
  xsh_pin: Str,
  sources: List[PlanSource],
  observations: List[PlanObservation],
  actions: List[PlanAction],
}

pure problem(kind: Str, message: Str, field: Str? = null) -> model.Problem {
  model.Problem(kind:, field:, message:)
}

pure help_problem(message: Str) -> model.Problem {
  problem("help", message)
}

pure usage(message: Str) -> model.Problem {
  problem("usage", message, field: "argv")
}

pure command_named(text: Str) -> Subcommand? {
  match text {
    "doctor" => Doctor,
    "plan" => Plan,
    "apply" => Apply,
    "check" => Check,
    "unlock" => Unlock,
    _ => null,
  }
}

## Returns the general usage text.
export pure general_help() -> Str {
  """xinfra — configuration management for Alpine hosts

Usage:
  xinfra doctor --inventory PATH [--deploy PATH] [--format FORMAT]
  xinfra plan --inventory PATH --deploy PATH [--limit LIST] [--exclude LIST] [--save-plan PATH] [--format FORMAT]
  xinfra apply --inventory PATH --deploy PATH [--plan PATH] [--limit LIST] [--exclude LIST] [--jobs N] [--on-error POLICY] [--format FORMAT]
  xinfra check --inventory PATH --deploy PATH [--limit LIST] [--exclude LIST] [--format FORMAT]
  xinfra unlock --inventory PATH --host NAME --force

Commands:
  doctor   Validate configuration and list selected hosts.
  plan     Compute ordered actions without touching a host.
  apply    Apply the computed actions.
  check    Report drift without mutating.
  unlock   Clear a host lock with an explicit force flag.

Options:
  --inventory PATH   Inventory TOML file.
  --deploy PATH      Deployment module.
  --limit LIST       Comma-separated host names or groups.
  --exclude LIST     Comma-separated host names or groups.
  --jobs N           Apply concurrency, default 8, maximum 64.
  --on-error POLICY  isolate, abort, or continue; default isolate.
  --format FORMAT    human, json, or jsonl; default human.
  --save-plan PATH   Write a versioned plan artifact.
  --plan PATH        Apply a previously saved plan.
  --host NAME        Host to unlock.
  --force            Confirm an unlock.
  -V, --version      Show the xinfra version.
  -h, --help         Show help.
"""
}

## Returns usage text for one subcommand.
export pure command_help(command: Subcommand) -> Str {
  match command {
    Doctor => """xinfra doctor — validate configuration and list selected hosts

Usage:
  xinfra doctor --inventory PATH [--deploy PATH] [--format human|json|jsonl]

Exit codes: 0 healthy, 1 unhealthy, 2 usage.
""",
    Plan => """xinfra plan — compute ordered actions without touching a host

Usage:
  xinfra plan --inventory PATH --deploy PATH [--limit LIST] [--exclude LIST]
              [--save-plan PATH] [--format human|json|jsonl]

Exit codes: 0 computed, 2 validation or transport error.
""",
    Apply => """xinfra apply — apply the computed actions

Usage:
  xinfra apply --inventory PATH --deploy PATH [--plan PATH] [--limit LIST]
               [--exclude LIST] [--jobs N] [--on-error isolate|abort|continue]
               [--format human|json|jsonl]

Exit codes: 0 success, 1 failed/blocked/unknown/partial, 2 usage/validation/stale plan, 130 interrupted.
""",
    Check => """xinfra check — report drift without mutating

Usage:
  xinfra check --inventory PATH --deploy PATH [--limit LIST] [--exclude LIST]
               [--format human|json|jsonl]

Exit codes: 0 compliant, 1 drift, 2 unknown or error.
""",
    Unlock => """xinfra unlock — clear a host lock with an explicit force flag

Usage:
  xinfra unlock --inventory PATH --host NAME --force [--format human|json|jsonl]

Exit codes: 0 success, 2 usage.
""",
  }
}

pure split_option(argument: Str) -> SplitOption {
  let equals = argument.find("=")
  if equals == null {
    return SplitOption(name: argument, value: null)
  }

  let position = equals ?? 0
  SplitOption(name: argument.byte_slice(0, position), value: argument.byte_slice(position + 1))
}

pure parse_path(value: Str) -> Result[Path, model.Problem] {
  match Path.parse_bytes(bytes.from_text(value)) {
    Ok(parsed) => Ok(parsed),
    Err(_) => Err(usage(f"invalid path {value}")),
  }
}

pure parse_list(value: Str) -> List[Str] {
  var items: List[Str] = []
  for item in value.split(",") {
    let trimmed = item.trim()
    if ! trimmed.is_empty() {
      items += [trimmed]
    }
  }

  items
}

pure parse_jobs(value: Str) -> Result[Int, model.Problem] {
  match value.parse_int() {
    Ok(parsed) => {
      if parsed < 1 or parsed > 64 {
        return Err(usage("--jobs must be between 1 and 64"))
      }

      Ok(parsed)
    }
    Err(_) => Err(usage(f"invalid --jobs value {value}")),
  }
}

pure allows_inventory(command: Subcommand) -> Bool {
  true
}

pure allows_deploy(command: Subcommand) -> Bool {
  match command {
    Unlock => false,
    _ => true,
  }
}

pure allows_selection(command: Subcommand) -> Bool {
  match command {
    Plan => true,
    Apply => true,
    Check => true,
    _ => false,
  }
}

pure allows_apply_policy(command: Subcommand) -> Bool {
  command == Apply
}

pure allows_save_plan(command: Subcommand) -> Bool {
  command == Plan
}

pure allows_load_plan(command: Subcommand) -> Bool {
  command == Apply
}

pure allows_unlock(command: Subcommand) -> Bool {
  command == Unlock
}

## Parses argv into typed options or a usage/help failure.
export pure parse(argv: List[Str]) -> Result[Options, model.Problem] {
  if argv.is_empty() {
    return Err(usage("missing command\n\n" + general_help()))
  }

  let first = argv[0]
  if first == "-h" or first == "--help" {
    return Err(help_problem(general_help()))
  }

  if first == "help" {
    if argv.len() == 1 {
      return Err(help_problem(general_help()))
    }

    let named = command_named(argv[1])
    if named == null {
      return Err(usage(f"unknown command {argv[1]}\n\n" + general_help()))
    }

    return Err(help_problem(command_help(named ?? Doctor)))
  }

  let named = command_named(first)
  if named == null {
    return Err(usage(f"unknown command {first}\n\n" + general_help()))
  }

  let command = named ?? Doctor
  var options = Options(command: command)
  var index = 1
  while index < argv.len() {
    let argument = argv[index]
    if argument == "-h" or argument == "--help" {
      options = {...options, help: true}
      index = index + 1
      continue
    }

    if ! argument.starts_with("--") {
      return Err(usage(f"unexpected argument {argument}"))
    }

    let split = split_option(argument)
    let name = split.name
    if name == "--force" {
      if split.value != null {
        return Err(usage("--force takes no value"))
      }

      if ! allows_unlock(command) {
        return Err(usage("--force is only valid for unlock"))
      }

      options = {...options, force: true}
      index = index + 1
      continue
    }

    var value = split.value ?? ""
    if split.value == null {
      if index + 1 >= argv.len() {
        return Err(usage(f"{name} requires a value"))
      }

      value = argv[index + 1]
      index = index + 1
    }
    index = index + 1

    if name == "--inventory" {
      if ! allows_inventory(command) {
        return Err(usage("--inventory is not valid for unlock"))
      }

      options = {...options, inventory: parse_path(value)?}
    } else if name == "--deploy" {
      if ! allows_deploy(command) {
        return Err(usage("--deploy is not valid for unlock"))
      }

      options = {...options, deploy: parse_path(value)?}
    } else if name == "--limit" {
      if ! allows_selection(command) {
        return Err(usage("--limit is only valid for plan, apply, and check"))
      }

      options = {...options, limit: options.limit + parse_list(value)}
    } else if name == "--exclude" {
      if ! allows_selection(command) {
        return Err(usage("--exclude is only valid for plan, apply, and check"))
      }

      options = {...options, exclude: options.exclude + parse_list(value)}
    } else if name == "--jobs" {
      if ! allows_apply_policy(command) {
        return Err(usage("--jobs is only valid for apply"))
      }

      options = {...options, jobs: parse_jobs(value)?}
    } else if name == "--on-error" {
      if ! allows_apply_policy(command) {
        return Err(usage("--on-error is only valid for apply"))
      }

      if value == "isolate" {
        options = {...options, on_error: Isolate}
      } else if value == "abort" {
        options = {...options, on_error: Abort}
      } else if value == "continue" {
        options = {...options, on_error: Continue}
      } else {
        return Err(usage(f"invalid --on-error value {value}"))
      }
    } else if name == "--format" {
      if value == "human" {
        options = {...options, style: report.Human}
      } else if value == "json" {
        options = {...options, style: report.Json}
      } else if value == "jsonl" {
        options = {...options, style: report.Jsonl}
      } else {
        return Err(usage(f"invalid --format value {value}"))
      }
    } else if name == "--save-plan" {
      if ! allows_save_plan(command) {
        return Err(usage("--save-plan is only valid for plan"))
      }

      options = {...options, save_plan: parse_path(value)?}
    } else if name == "--plan" {
      if ! allows_load_plan(command) {
        return Err(usage("--plan is only valid for apply"))
      }

      options = {...options, plan: parse_path(value)?}
    } else if name == "--host" {
      if ! allows_unlock(command) {
        return Err(usage("--host is only valid for unlock"))
      }

      if value.is_empty() {
        return Err(usage("--host requires a name"))
      }

      options = {...options, host: value}
    } else {
      return Err(usage(f"unknown option {name}"))
    }
  }

  if options.help {
    return Ok(options)
  }

  match command {
    Doctor => {
      if options.inventory == null {
        return Err(usage("doctor requires --inventory"))
      }
    }
    Plan => {
      if options.inventory == null or options.deploy == null {
        return Err(usage("plan requires --inventory and --deploy"))
      }
    }
    Apply => {
      if options.inventory == null {
        return Err(usage("apply requires --inventory"))
      }

      if options.deploy == null and options.plan == null {
        return Err(usage("apply requires --deploy or --plan"))
      }
    }
    Check => {
      if options.inventory == null or options.deploy == null {
        return Err(usage("check requires --inventory and --deploy"))
      }
    }
    Unlock => {
      if options.host == null {
        return Err(usage("unlock requires --host"))
      }

      if ! options.force {
        return Err(usage("unlock requires --force"))
      }
    }
  }

  Ok(options)
}

## Selects hosts by limit and excludes selectors, preserving inventory order.
export pure select_hosts(
  loaded: inventory.Inventory,
  limit: List[Str],
  exclude: List[Str],
) -> Result[inventory.Inventory, model.Problem] {
  let chosen = match inventory.select(loaded, limit) {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("selector", failure.message, field: "limit"))
    },
  }
  var removed: List[inventory.Host] = []
  if ! exclude.is_empty() {
    removed = match inventory.select(loaded, exclude) {
      Ok(value) => value,
      Err(failure) => {
        return Err(problem("selector", failure.message, field: "exclude"))
      },
    }
  }
  var hosts: List[inventory.Host] = []
  for host in chosen {
    var keep = true
    for excluded in removed {
      if excluded.name == host.name {
        keep = false
      }
    }

    if keep {
      hosts += [host]
    }
  }

  Ok(inventory.Inventory(groups: loaded.groups, hosts: hosts))
}

proc load_inventory(file: Path) -> Result[inventory.Inventory, model.Problem] {
  match inventory.load(file) {
    Ok(value) => Ok(value),
    Err(failure) => Err(problem("inventory", failure.message, field: "inventory")),
  }
}

proc observed_for(ops: host.HostOps, resource: model.Resource) [fs, env, error] -> plan.Observed {
  match resource {
    model.Directory(spec) => {
      match ops.inspect_path(spec.path) {
        Ok(value) => host.observed(value),
        Err(_) => plan.Unknown,
      }
    }
    model.File(spec) => {
      match ops.inspect_path(spec.path) {
        Ok(value) => host.observed(value),
        Err(_) => plan.Unknown,
      }
    }
    model.Symlink(spec) => {
      match ops.inspect_path(spec.path) {
        Ok(value) => host.observed(value),
        Err(_) => plan.Unknown,
      }
    }
    _ => plan.Unknown,
  }
}

proc gather_facts(
  ops: host.HostOps?,
  allow_remote: Bool,
  deployment: validate.Deployment,
  selected: inventory.Inventory,
  sessions: Map[Str, transport.Session]? = null,
) [fs, env, process, io, error] -> Result[plan.Facts, model.Problem] {
  if ops == null {
    if ! allow_remote {
      var names: List[Str] = []
      for entry in selected.hosts {
        names += [entry.name]
      }

      return Ok(plan.empty_facts(names))
    }

    var entries: List[plan.HostFacts] = []
    for entry in selected.hosts {
      var resources: List[model.Resource] = []
      for resource in deployment.resources {
        if model.applies_to(resource, entry.name, entry.groups) {
          resources += [resource]
        }
      }
      var observed: Map[Str, plan.Observed] = map.empty()
      if sessions == null {
        observed = match driver.observe_all(entry, resources) {
          Ok(value) => value,
          Err(failure) => {
            return Err(problem("transport", f"cannot read facts on {entry.name}: {failure.message}", field: "transport"))
          },
        }
      } else {
        let session_map = sessions ?? map.empty()
        let session = match session_map.get(entry.name) {
          Ok(value) => value,
          Err(_) => {
            return Err(problem("transport", f"no session for {entry.name}", field: "transport"))
          },
        }
        observed = match driver.observe_all_on(session, resources) {
          Ok(value) => value,
          Err(failure) => {
            return Err(problem("transport", f"cannot read facts on {entry.name}: {failure.message}", field: "transport"))
          },
        }
      }
      entries += [plan.HostFacts(name: entry.name, observed: observed)]
    }
    return Ok(plan.Facts(hosts: entries))
  }

  let handle = ops
  var entries: List[plan.HostFacts] = []
  for entry in selected.hosts {
    var observed: Map[Str, plan.Observed] = map.empty()
    for resource in deployment.resources {
      if model.applies_to(resource, entry.name, entry.groups) {
        observed = observed.set(model.identity(resource), observed_for(handle, resource))
      }
    }

    entries += [plan.HostFacts(name: entry.name, observed: observed)]
  }

  Ok(plan.Facts(hosts: entries))
}

proc compute(
  options: Options,
  ops: host.HostOps?,
  allow_remote: Bool,
  root: Path,
  sessions: Map[Str, transport.Session]? = null,
) [fs, env, process, io, error] -> Result[Computed, model.Problem] {
  let inventory_file = options.inventory ?? p""
  var deploy_file = options.deploy ?? p""
  if options.deploy == null and options.plan != null {
    let artifact = load_plan(options.plan ?? p"")?
    deploy_file = match Path.parse_bytes(bytes.from_text(artifact.deployment)) {
      Ok(value) => value,
      Err(_) => {
        return Err(problem("stale-plan", "saved plan deployment path is invalid", field: "plan"))
      },
    }
  }
  let loaded = load_inventory(inventory_file)?
  let selected = select_hosts(loaded, options.limit, options.exclude)?
  let deployment = validate.load(deploy_file, loaded, root)?
  let facts = gather_facts(ops, allow_remote, deployment, selected, sessions)?
  let actions = plan.plan(deployment, selected, facts)
  Ok(
    Computed(
      inventory: selected,
      deployment: deployment,
      deployment_file: deploy_file,
      inventory_file: inventory_file,
      facts: facts,
      actions: actions,
    ),
  )
}

proc action_rows(run_id: Str, actions: List[plan.Action], phase: Str) -> List[report.ResultRow] {
  var rows: List[report.ResultRow] = []
  for action in actions {
    rows += [
      report.row(
        run_id,
        action.host,
        action.id,
        phase,
        outcome.of_prediction(action.prediction),
        action.prediction == plan.Unchanged,
        action.cause ?? "",
        0,
      ),
    ]
  }

  rows
}

pure with_host(value: host.ApplyResult, target: Str) -> host.ApplyResult {
  host.ApplyResult(
    id: value.id,
    host: target,
    status: value.status,
    verified: value.verified,
    cause: value.cause,
  )
}

proc apply_resource(ops: host.HostOps, action: plan.Action) [fs, env, error] -> host.ApplyResult {
  match action.resource {
    model.Directory(spec) => dir.apply(ops, spec),
    model.File(spec) => file.apply(ops, spec, action.source),
    model.Symlink(spec) => symlink.apply(ops, spec),
    _ => host.failed(ops, action.id, "resource kind is not available without a remote transport"),
  }
}

pure failure_status(value: host.ApplyStatus) -> Bool {
  value == host.Failed or value == host.Unknown or value == host.Partial or value == host.Blocked
}

## Applies actions in order under the selected failure policy.
export proc apply_actions(
  ops: host.HostOps,
  actions: List[plan.Action],
  policy: OnError,
) [fs, env, time, error] -> List[Applied] {
  var applied: List[Applied] = []
  var stopped: Set[Str] = set.empty()
  var failed: Map[Str, Set[Str]] = map.empty()
  var aborted = false
  for action in actions {
    let host_failures: Set[Str] = failed.get(action.host) ?? set.empty()
    var skip_cause: Str? = null
    var skipped = false
    if aborted {
      skip_cause = "aborted after an earlier failure"
      skipped = true
    } else if action.host in stopped {
      skip_cause = "host stopped after a failure"
      skipped = true
    } else {
      for requirement in model.requirements(action.resource) {
        if requirement in host_failures {
          skip_cause = f"prerequisite {requirement} failed"
        }
      }
    }

    if skip_cause != null {
      let status = if skipped { host.Skipped } else { host.Blocked }
      applied += [
        Applied(
          result: host.ApplyResult(
            id: action.id,
            host: action.host,
            status: status,
            verified: false,
            cause: skip_cause,
          ),
          duration_ms: 0,
        ),
      ]
      if ! skipped {
        failed = failed.set(action.host, host_failures.add(action.id))
        if policy == Isolate {
          stopped = stopped.add(action.host)
        } else if policy == Abort {
          aborted = true
        }
      }
      continue
    }

    if action.prediction == plan.Blocked {
      applied += [
        Applied(
          result: host.ApplyResult(
            id: action.id,
            host: action.host,
            status: host.Blocked,
            verified: false,
            cause: action.cause ?? "blocked by the current plan",
          ),
          duration_ms: 0,
        ),
      ]
      failed = failed.set(action.host, host_failures.add(action.id))
      if policy == Isolate {
        stopped = stopped.add(action.host)
      } else if policy == Abort {
        aborted = true
      }
      continue
    }

    let started = time.monotonic()?
    let result = with_host(apply_resource(ops, action), action.host)
    let elapsed = (time.monotonic()? - started) / 1000000
    applied += [Applied(result: result, duration_ms: elapsed)]
    if failure_status(result.status) {
      failed = failed.set(action.host, host_failures.add(action.id))
      if policy == Isolate {
        stopped = stopped.add(action.host)
      } else if policy == Abort {
        aborted = true
      }
    }
  }

  applied
}

proc applied_rows(run_id: Str, applied: List[Applied], phase: Str) -> List[report.ResultRow] {
  var rows: List[report.ResultRow] = []
  for entry in applied {
    rows += [
      report.row(
        run_id,
        entry.result.host,
        entry.result.id,
        phase,
        outcome.of_status(entry.result.status),
        entry.result.verified,
        entry.result.cause ?? "",
        entry.duration_ms,
      ),
    ]
  }

  rows
}

proc digest_file(file: Path) [fs, error] -> Result[Str, model.Problem] {
  match hash.sha256(file) {
    Ok(value) => Ok(value.hex()),
    Err(failure) => Err(problem("plan", failure.message, field: "plan")),
  }
}

pure plan_actions(actions: List[plan.Action]) -> List[PlanAction] {
  var entries: List[PlanAction] = []
  for action in actions {
    entries += [
      PlanAction(id: action.id, host: action.host, operation: outcome.operation_text(action.operation)),
    ]
  }

  entries
}

pure optional_bool(value: Bool?) -> Str {
  if value == null {
    return "?"
  }
  if value ?? false {
    return "yes"
  }
  "no"
}

pure observed_text(value: plan.Observed) -> Str {
  match value {
    plan.Absent => "absent"
    plan.Existing(facts) => f"existing:{facts.kind}:{facts.mode}:{facts.owner ?? ""}:{facts.group ?? ""}:{facts.digest ?? ""}:{facts.target?.display() ?? ""}:{facts.empty}"
    plan.Installed(facts) => f"installed:{facts.version ?? ""}:{optional_bool(facts.satisfies)}"
    plan.Account(facts) => f"account:{facts.uid}:{facts.gid}:{facts.groups.join(",")}:{facts.home?.display() ?? ""}:{facts.shell?.display() ?? ""}"
    plan.Role(facts) => f"role:{facts.gid}"
    plan.Invocation(facts) => f"invocation:{optional_bool(facts.creates_present)}:{optional_bool(facts.unless_satisfied)}"
    plan.Running(facts) => f"running:{facts.started}:{optional_bool(facts.enabled)}"
    plan.Unknown => "unknown"
  }
}

pure plan_sources(deployment: validate.Deployment) -> List[PlanSource] {
  var sources: List[PlanSource] = []
  for {key: id, value: source} in deployment.sources {
    let digest = validate.digest(source)
    if digest != null {
      sources += [PlanSource(id: id, digest: digest ?? "")]
    }
  }
  sources
}

pure plan_observations(facts: plan.Facts) -> List[PlanObservation] {
  var observations: List[PlanObservation] = []
  for host in facts.hosts {
    let resources = host.observed.keys() |> sort() |> collect()
    for resource in resources {
      match host.observed.get(resource) {
        Ok(value) => { observations += [PlanObservation(host: host.name, resource: resource, fact: observed_text(value))] }
        Err(_) => {}
      }
    }
  }
  observations
}

proc save_plan(
  target: Path,
  run_id: Str,
  deployment_file: Path,
  inventory_file: Path,
  deployment: validate.Deployment,
  facts: plan.Facts,
  actions: List[plan.Action],
) [fs, env, error] -> Result[Unit, model.Problem] {
  for action in actions {
    if action.prediction == plan.Undetermined {
      return Err(problem("plan", "a plan with unknown actions cannot be saved", field: "save-plan"))
    }
  }

  let deployment_digest = digest_file(deployment_file)?
  let inventory_digest = digest_file(inventory_file)?
  let xsh_pin = match env.get_or("XSH_PIN", "") {
    Ok(value) => value.trim(),
    Err(_) => "",
  }
  let artifact = PlanArtifact(
    schema_version: 1,
    kind: "plan",
    run_id: run_id,
    deployment: deployment_file.display(),
    inventory: inventory_file.display(),
    deployment_digest: deployment_digest,
    inventory_digest: inventory_digest,
    version: version.VERSION,
    xsh_pin: xsh_pin,
    sources: plan_sources(deployment),
    observations: plan_observations(facts),
    actions: plan_actions(actions),
  )
  match json.write(target, artifact, pretty: true) {
    Ok(_) => Ok(),
    Err(failure) => Err(problem("plan", failure.message, field: "save-plan")),
  }
}

proc load_plan(target: Path) [fs, error] -> Result[PlanArtifact, model.Problem] {
  let raw = match json.read(target) {
    Ok(value) => value,
    Err(failure) => {
      return Err(problem("stale-plan", failure.message, field: "plan"))
    },
  }
  match raw.require_exact(PlanArtifact) {
    Ok(value) => {
      if value.schema_version != 1 or value.kind != "plan" {
        return Err(problem("stale-plan", "saved plan schema or kind is not supported", field: "plan"))
      }
      Ok(value)
    }
    Err(failure) => Err(problem("stale-plan", failure.message, field: "plan")),
  }
}

proc check_plan(
  artifact: PlanArtifact,
  deployment_file: Path,
  inventory_file: Path,
  deployment: validate.Deployment,
  facts: plan.Facts,
  actions: List[plan.Action],
  xsh_pin: Str,
) [fs, error] -> Result[Unit, model.Problem] {
  let deployment_digest = digest_file(deployment_file)?
  let inventory_digest = digest_file(inventory_file)?
  if artifact.deployment_digest != deployment_digest {
    return Err(problem("stale-plan", "deployment changed since the plan was saved", field: "plan"))
  }

  if artifact.inventory_digest != inventory_digest {
    return Err(problem("stale-plan", "inventory changed since the plan was saved", field: "plan"))
  }

  if artifact.version != version.VERSION {
    return Err(problem("stale-plan", "xinfra version changed since the plan was saved", field: "plan"))
  }

  if artifact.xsh_pin != xsh_pin {
    return Err(problem("stale-plan", "XSH pin changed since the plan was saved", field: "plan"))
  }

  if artifact.sources != plan_sources(deployment) {
    return Err(problem("stale-plan", "a source changed since the plan was saved", field: "plan"))
  }

  if artifact.observations != plan_observations(facts) {
    return Err(problem("stale-plan", "an observed precondition changed since the plan was saved", field: "plan"))
  }

  if artifact.actions != plan_actions(actions) {
    return Err(problem("stale-plan", "planned actions changed since the plan was saved", field: "plan"))
  }

  Ok()
}

pure execution(exit_code: Int, stdout: Str, stderr: Str) -> Execution {
  Execution(exit: exit_code, stdout: stdout, stderr: stderr)
}

proc render_report(
  run_id: Str,
  rows: List[report.ResultRow],
  exit_code: Int,
  style: report.Style,
  redactor: redact.Redactor,
) -> Result[Execution, Error] {
  let built = report.build(run_id, rows, exit_code)
  match report.render(built, style, redactor) {
    Ok(text) => Ok(execution(exit_code, text, "")),
    Err(failure) => Ok(execution(2, "", report.clean(failure.message, redactor) + "\n")),
  }
}

proc doctor(
  options: Options,
  root: Path,
  run_id: Str,
  style: report.Style,
  redactor: redact.Redactor,
) [fs, error] -> Execution {
  let inventory_file = options.inventory ?? p""
  let loaded = match load_inventory(inventory_file) {
    Ok(value) => value,
    Err(failure) => {
      let rows = [
        report.row(run_id, "-", "inventory", "doctor", outcome.Failed, false, failure.message, 0),
      ]
      return match render_report(run_id, rows, 1, style, redactor) {
        Ok(value) => value,
        Err(failure) => execution(2, "", failure.message + "\n"),
      }
    },
  }
  if options.deploy != null {
    let deploy_file = options.deploy ?? p""
    match validate.load(deploy_file, loaded, root) {
      Ok(_) => {}
      Err(failure) => {
        let rows = [
          report.row(run_id, "-", "deploy", "doctor", outcome.Failed, false, failure.message, 0),
        ]
        return match render_report(run_id, rows, 1, style, redactor) {
          Ok(value) => value,
          Err(failure) => execution(2, "", failure.message + "\n"),
        }
      },
    }
  }

  var rows: List[report.ResultRow] = []
  for host in loaded.hosts {
    rows += [report.row(run_id, host.name, "host", "doctor", outcome.Unchanged, true, "", 0)]
  }
  match render_report(run_id, rows, 0, style, redactor) {
    Ok(value) => value,
    Err(failure) => execution(2, "", failure.message + "\n"),
  }
}

proc run_plan(
  options: Options,
  computed: Computed,
  root: Path,
  run_id: Str,
  redactor: redact.Redactor,
) [fs, env, error] -> Execution {
  if options.save_plan != null {
    let target = options.save_plan ?? p""
    match save_plan(target, run_id, computed.deployment_file, computed.inventory_file, computed.deployment, computed.facts, computed.actions) {
      Ok(_) => {}
      Err(failure) => {
        return execution(2, "", report.clean(failure.message, redactor) + "\n")
      },
    }
  }

  let rows = action_rows(run_id, computed.actions, "plan")
  match render_report(run_id, rows, 0, options.style, redactor) {
    Ok(value) => value,
    Err(failure) => execution(2, "", failure.message + "\n"),
  }
}

proc run_check(
  options: Options,
  computed: Computed,
  run_id: Str,
  redactor: redact.Redactor,
) -> Result[Execution, Error] {
  let rows = action_rows(run_id, computed.actions, "check")
  var outcomes: List[outcome.Outcome] = []
  for row in rows {
    outcomes += [row.outcome]
  }

  let exit_code = outcome.check_exit(outcome.counts(outcomes))
  render_report(run_id, rows, exit_code, options.style, redactor)
}

proc no_transport_rows(run_id: Str, actions: List[plan.Action]) -> List[report.ResultRow] {
  var rows: List[report.ResultRow] = []
  for action in actions {
    rows += [
      report.row(
        run_id,
        action.host,
        action.id,
        "apply",
        outcome.Failed,
        false,
        "no host transport is available",
        0,
      ),
    ]
  }

  rows
}

pure action_key(action: plan.Action) -> Str {
  f"{action.host}:{action.id}"
}

pure action_stages(actions: List[plan.Action]) -> List[List[plan.Action]] {
  var stages: List[List[plan.Action]] = []
  var stage: List[plan.Action] = []
  var current = ""
  for action in actions {
    if stage.is_empty() {
      stage = [action]
      current = action.id
    } else if action.id == current {
      stage += [action]
    } else {
      stages += [stage]
      stage = [action]
      current = action.id
    }
  }
  if ! stage.is_empty() {
    stages += [stage]
  }
  stages
}

pure failure_result(id: Str, host_name: Str, message: Str) -> host.ApplyResult {
  host.ApplyResult(
    id: id,
    host: host_name,
    status: if transport.after_submission(message) { host.Unknown } else { host.Failed },
    verified: false,
    cause: message,
  )
}

pure missing_host(id: Str, host_name: Str) -> host.ApplyResult {
  host.ApplyResult(
    id: id,
    host: host_name,
    status: host.Failed,
    verified: false,
    cause: "host is missing from the selected inventory",
  )
}

proc run_action(
  action: plan.Action,
  hosts: Map[Str, inventory.Host],
  sessions: Map[Str, transport.Session]?,
) [fs, env, time, process, io, error] -> Applied {
  let started = time.monotonic()?
  let result = match hosts.get(action.host) {
    Ok(entry) => match sessions {
      null => match driver.apply(entry, action.resource, action.source) {
        Ok(value) => value,
        Err(failure) => failure_result(action.id, action.host, failure.message),
      },
      value => {
        let session_map = value ?? map.empty()
        match session_map.get(action.host) {
          Ok(session) => match driver.apply_on(session, entry, action.resource, action.source) {
            Ok(applied) => applied,
            Err(failure) => failure_result(action.id, action.host, failure.message),
          },
          Err(_) => match driver.apply(entry, action.resource, action.source) {
            Ok(applied) => applied,
            Err(failure) => failure_result(action.id, action.host, failure.message),
          },
        }
      },
    },
    Err(_) => missing_host(action.id, action.host),
  }
  let elapsed = (time.monotonic()? - started) / 1000000
  Applied(result: with_host(result, action.host), duration_ms: elapsed)
}

proc run_notification(
  action: plan.Action,
  spec: model.ServiceSpec,
  hosts: Map[Str, inventory.Host],
  sessions: Map[Str, transport.Session]?,
) [fs, env, time, process, io, error] -> Applied {
  let started = time.monotonic()?
  let result = match hosts.get(action.host) {
    Ok(entry) => match sessions {
      null => match driver.notify(entry, spec) {
        Ok(value) => value,
        Err(failure) => failure_result(spec.id, action.host, failure.message),
      },
      value => {
        let session_map = value ?? map.empty()
        match session_map.get(action.host) {
          Ok(session) => match driver.notify_on(session, entry, spec) {
            Ok(applied) => applied,
            Err(failure) => failure_result(spec.id, action.host, failure.message),
          },
          Err(_) => match driver.notify(entry, spec) {
            Ok(applied) => applied,
            Err(failure) => failure_result(spec.id, action.host, failure.message),
          },
        }
      },
    },
    Err(_) => missing_host(spec.id, action.host),
  }
  let elapsed = (time.monotonic()? - started) / 1000000
  let identified = host.ApplyResult(
    id: spec.id,
    host: action.host,
    status: result.status,
    verified: result.verified,
    cause: result.cause,
  )
  Applied(result: identified, duration_ms: elapsed)
}

pure merge_notification(base: Applied, notified: Applied) -> Applied {
  let status = match notified.result.status {
    host.Changed => if base.result.status == host.Unchanged { host.Changed } else { base.result.status },
    host.Unchanged => base.result.status,
    other => other,
  }
  let notified_cause = notified.result.cause ?? ""
  let cause = if notified_cause.is_empty() { base.result.cause } else { notified.result.cause }
  Applied(
    result: host.ApplyResult(
      id: base.result.id,
      host: base.result.host,
      status: status,
      verified: status == host.Changed or status == host.Unchanged,
      cause: cause,
    ),
    duration_ms: base.duration_ms + notified.duration_ms,
  )
}

proc apply_actions_remote(
  computed: Computed,
  actions: List[plan.Action],
  policy: OnError,
  jobs: Int,
  sessions: Map[Str, transport.Session]? = null,
) [fs, env, time, process, io, error] -> List[Applied] {
  var hosts: Map[Str, inventory.Host] = map.empty()
  for entry in computed.inventory.hosts {
    hosts = hosts.set(entry.name, entry)
  }

  var applied: List[Applied] = []
  var stopped: Set[Str] = set.empty()
  var failed: Map[Str, Set[Str]] = map.empty()
  var aborted = false
  for stage in action_stages(actions) {
    var stage_rows: Map[Str, Applied] = map.empty()
    var runnable: List[plan.Action] = []
    for action in stage {
      let host_failures: Set[Str] = failed.get(action.host) ?? set.empty()
      var skip_cause: Str? = null
      var skipped = false
      if aborted {
        skip_cause = "aborted after an earlier failure"
        skipped = true
      } else if action.host in stopped {
        skip_cause = "host stopped after a failure"
        skipped = true
      } else {
        for requirement in model.requirements(action.resource) {
          if requirement in host_failures {
            skip_cause = f"prerequisite {requirement} failed"
          }
        }
      }

      if skip_cause != null {
        let status = if skipped { host.Skipped } else { host.Blocked }
        stage_rows = stage_rows.set(
          action_key(action),
          Applied(
            result: host.ApplyResult(
              id: action.id,
              host: action.host,
              status: status,
              verified: false,
              cause: skip_cause,
            ),
            duration_ms: 0,
          ),
        )
        if ! skipped {
          failed = failed.set(action.host, host_failures.add(action.id))
          if policy == Isolate {
            stopped = stopped.add(action.host)
          } else if policy == Abort {
            aborted = true
          }
        }
        continue
      }

      if action.prediction == plan.Blocked {
        stage_rows = stage_rows.set(
          action_key(action),
          Applied(
            result: host.ApplyResult(
              id: action.id,
              host: action.host,
              status: host.Blocked,
              verified: false,
              cause: action.cause ?? "blocked by the current plan",
            ),
            duration_ms: 0,
          ),
        )
        failed = failed.set(action.host, host_failures.add(action.id))
        if policy == Isolate {
          stopped = stopped.add(action.host)
        } else if policy == Abort {
          aborted = true
        }
        continue
      }

      runnable += [action]
    }

    if ! runnable.is_empty() {
      let batch = runnable |> par-map(jobs: jobs) { |action| run_action(action, hosts, sessions) }
      for index in range(runnable.len()) {
        let action = runnable[index]
        let outcome_value = batch[index]
        stage_rows = stage_rows.set(action_key(action), outcome_value)
        if failure_status(outcome_value.result.status) {
          let host_failures: Set[Str] = failed.get(action.host) ?? set.empty()
          failed = failed.set(action.host, host_failures.add(action.id))
          if policy == Isolate {
            stopped = stopped.add(action.host)
          } else if policy == Abort {
            aborted = true
          }
        }
      }
    }

    for action in stage {
      match stage_rows.get(action_key(action)) {
        Ok(value) => { applied += [value] },
        Err(_) => {
          applied += [Applied(result: missing_host(action.id, action.host), duration_ms: 0)]
        },
      }
    }
  }

  var changed_by_host: Map[Str, List[Str]] = map.empty()
  for index in range(actions.len()) {
    if applied[index].result.status == host.Changed {
      let ids = changed_by_host.get(actions[index].host) ?? []
      changed_by_host = changed_by_host.set(actions[index].host, ids + [actions[index].id])
    }
  }
  var service_status: Map[Str, host.ApplyStatus] = map.empty()
  for index in range(actions.len()) {
    match actions[index].resource {
      model.ServiceResource(spec) => {
        service_status = service_status.set(f"{actions[index].host}:{spec.id}", applied[index].result.status)
      }
      _ => {}
    }
  }

  let resources = actions |> map .resource
  var notifications: Map[Str, Applied] = map.empty()
  for index in range(actions.len()) {
    let action = actions[index]
    match action.resource {
      model.ServiceResource(spec) => {
        if aborted or action.host in stopped or spec.state != model.Started {
          continue
        }
        let status = service_status.get(f"{action.host}:{spec.id}") ?? host.Unknown
        if status != host.Changed and status != host.Unchanged {
          continue
        }
        let changed_ids = changed_by_host.get(action.host) ?? []
        if spec.id in notify.coalesce(changed_ids, resources) {
          notifications = notifications.set(action_key(action), run_notification(action, spec, hosts, sessions))
        }
      }
      _ => {}
    }
  }

  var merged: List[Applied] = []
  for index in range(actions.len()) {
    let action = actions[index]
    match notifications.get(action_key(action)) {
      Ok(value) => { merged += [merge_notification(applied[index], value)] },
      Err(_) => { merged += [applied[index]] },
    }
  }
  merged
}

proc release_locks(
  hosts: List[inventory.Host],
  run_id: Str,
  sessions: Map[Str, transport.Session],
) [fs, process, io, error] {
  for entry in hosts {
    let token = f"{run_id}:{entry.name}"
    match sessions.get(entry.name) {
      Ok(session) => { let _ = driver.release_lock_on(session, entry, token) },
      Err(_) => { let _ = driver.release_lock(entry, token) },
    }
  }
}

proc run_apply_locked(
  options: Options,
  computed: Computed,
  ops: host.HostOps?,
  allow_remote: Bool,
  root: Path,
  run_id: Str,
  secured: redact.Redactor,
  sessions: Map[Str, transport.Session]? = null,
) [fs, env, time, process, io, error] -> Execution {
  if options.plan != null {
    let plan_file = options.plan ?? p""
    let artifact = match load_plan(plan_file) {
      Ok(value) => value,
      Err(failure) => {
        return execution(2, "", report.clean(failure.message, secured) + "\n")
      },
    }
    let xsh_pin = match env.get_or("XSH_PIN", "") {
      Ok(value) => value.trim(),
      Err(_) => "",
    }
    match check_plan(
      artifact,
      computed.deployment_file,
      computed.inventory_file,
      computed.deployment,
      computed.facts,
      computed.actions,
      xsh_pin,
    ) {
      Ok(_) => {}
      Err(failure) => {
        return execution(2, "", report.clean(failure.message, secured) + "\n")
      },
    }
  }

  var rows: List[report.ResultRow] = []
  if ops == null and allow_remote {
    let applied = apply_actions_remote(computed, computed.actions, options.on_error, options.jobs, sessions)
    rows = applied_rows(run_id, applied, "apply")
  } else if ops == null {
    rows = no_transport_rows(run_id, computed.actions)
  } else {
    let applied = apply_actions(ops, computed.actions, options.on_error)
    rows = applied_rows(run_id, applied, "apply")
  }
  var outcomes: List[outcome.Outcome] = []
  for row in rows {
    outcomes += [row.outcome]
  }

  let exit_code = outcome.apply_exit(outcome.counts(outcomes))
  match render_report(run_id, rows, exit_code, options.style, secured) {
    Ok(value) => value,
    Err(failure) => execution(2, "", failure.message + "\n"),
  }
}

proc lock_failure(
  options: Options,
  run_id: Str,
  host_name: Str,
  message: Str,
  secured: redact.Redactor,
) -> Execution {
  let rows = [
    report.row(run_id, host_name, "lock", "apply", outcome.Failed, false, message, 0),
  ]
  match render_report(run_id, rows, 1, options.style, secured) {
    Ok(value) => value,
    Err(render_failure) => execution(2, "", render_failure.message + "\n"),
  }
}

proc run_apply(
  options: Options,
  computed: Computed,
  ops: host.HostOps?,
  allow_remote: Bool,
  root: Path,
  run_id: Str,
  redactor: redact.Redactor,
) [fs, env, time, process, io, error] -> Execution {
  let secured = secret.redactor(computed.deployment)
  if ops != null or ! allow_remote {
    return run_apply_locked(options, computed, ops, allow_remote, root, run_id, secured)
  }

  var sessions: Map[Str, transport.Session] = map.empty()
  for entry in computed.inventory.hosts {
    match driver.connect(entry) {
      Ok(session) => { sessions = sessions.set(entry.name, session) },
      Err(failure) => {
        for session in sessions.values() {
          let _ = transport.close(session)
        }
        return lock_failure(options, run_id, entry.name, failure.message, secured)
      },
    }
  }
  defer {
    for session in sessions.values() {
      let _ = transport.close(session)
    }
  }
  var acquired: List[inventory.Host] = []
  defer {
    release_locks(acquired, run_id, sessions)
  }
  for entry in computed.inventory.hosts {
    let token = f"{run_id}:{entry.name}"
    let session = match sessions.get(entry.name) {
      Ok(value) => value,
      Err(_) => {
        return lock_failure(options, run_id, entry.name, "session disappeared", secured)
      },
    }
    match driver.lock_on(session, entry, token) {
      Ok(_) => { acquired += [entry] },
      Err(failure) => {
        return lock_failure(options, run_id, entry.name, failure.message, secured)
      },
    }
  }

  let locked = match compute(options, ops, allow_remote, root, sessions) {
    Ok(value) => value,
    Err(failure) => {
      return execution(2, "", report.clean(failure.message, secured) + "\n")
    },
  }
  run_apply_locked(options, locked, ops, allow_remote, root, run_id, secured, sessions)
}

proc run_unlock(
  options: Options,
  allow_remote: Bool,
  root: Path,
  run_id: Str,
  redactor: redact.Redactor,
) [fs, process, io, error] -> Execution {
  let requested = options.host ?? ""
  if ! allow_remote {
    let rows = [report.row(run_id, requested, "lock", "unlock", outcome.Changed, true, "lock released", 0)]
    return match render_report(run_id, rows, 0, options.style, redactor) {
      Ok(value) => value,
      Err(failure) => execution(2, "", failure.message + "\n"),
    }
  }
  if options.inventory == null {
    return execution(2, "", "unlock requires --inventory PATH\n")
  }
  let inventory_file = options.inventory ?? p""
  let loaded = match load_inventory(inventory_file) {
    Ok(value) => value,
    Err(failure) => {
      return execution(2, "", report.clean(failure.message, redactor) + "\n")
    },
  }
  var entry: inventory.Host? = null
  for host in loaded.hosts {
    if host.name == requested {
      entry = host
    }
  }
  if entry == null {
    return execution(2, "", f"host {requested} is not in the inventory\n")
  }
  match driver.unlock(entry ?? loaded.hosts[0]) {
    Ok(_) => {
      let rows = [report.row(run_id, requested, "lock", "unlock", outcome.Changed, true, "lock removed", 0)]
      match render_report(run_id, rows, 0, options.style, redactor) {
        Ok(value) => value,
        Err(failure) => execution(2, "", failure.message + "\n"),
      }
    }
    Err(failure) => {
      let rows = [report.row(run_id, requested, "lock", "unlock", outcome.Failed, false, failure.message, 0)]
      match render_report(run_id, rows, 1, options.style, redactor) {
        Ok(value) => value,
        Err(render_failure) => execution(2, "", render_failure.message + "\n"),
      }
    },
  }
}

proc dispatch(
  options: Options,
  ops: host.HostOps?,
  allow_remote: Bool,
  root: Path,
  run_id: Str,
  redactor: redact.Redactor,
) [fs, env, time, process, io, error] -> Execution {
  if options.help {
    return execution(0, command_help(options.command), "")
  }

  match options.command {
    Unlock => run_unlock(options, allow_remote, root, run_id, redactor),
    Doctor => doctor(options, root, run_id, options.style, redactor),
    Plan => {
      let computed = match compute(options, ops, allow_remote, root) {
        Ok(value) => value,
        Err(failure) => {
          return execution(2, "", report.clean(failure.message, redactor) + "\n")
        },
      }
      run_plan(options, computed, root, run_id, redactor)
    }
    Check => {
      let computed = match compute(options, ops, allow_remote, root) {
        Ok(value) => value,
        Err(failure) => {
          return execution(2, "", report.clean(failure.message, redactor) + "\n")
        },
      }
      match run_check(options, computed, run_id, redactor) {
        Ok(value) => value,
        Err(failure) => execution(2, "", report.clean(failure.message, redactor) + "\n"),
      }
    }
    Apply => {
      let computed = match compute(options, ops, allow_remote, root) {
        Ok(value) => value,
        Err(failure) => {
          return execution(2, "", report.clean(failure.message, redactor) + "\n")
        },
      }
      run_apply(options, computed, ops, allow_remote, root, run_id, redactor)
    }
  }
}

## Executes one invocation and returns its output and exit code.
export proc execute(
  argv: List[Str],
  ops: host.HostOps?,
  root: Path,
  run_id: Str = "",
  redactor: redact.Redactor = redact.empty(),
  allow_remote: Bool = false,
) [fs, env, time, process, io, error] -> Execution {
  if argv == ["--version"] or argv == ["-V"] {
    return execution(0, f"xinfra {version.VERSION}\n", "")
  }
  let effective_run_id = if run_id.is_empty() { f"run-{time.now()}" } else { run_id }
  let attempted = try {
    let parsed = parse(argv)
    match parsed {
      Err(failure) => {
        if failure.kind == "help" {
          return execution(0, failure.message, "")
        }

        return execution(2, "", report.clean(failure.message, redactor) + "\n")
      }
      Ok(options) => dispatch(options, ops, allow_remote, root, effective_run_id, redactor),
    }
  }
  match attempted {
    Ok(value) => value,
    Err(failure) => execution(2, "", report.clean(failure.message, redactor) + "\n"),
  }
}

## Prints one invocation's output and returns its exit code.
export proc run_cli(
  argv: List[Str],
  ops: host.HostOps?,
  root: Path,
  redactor: redact.Redactor = redact.empty(),
  allow_remote: Bool = false,
) [fs, env, time, process, io, error] -> Int {
  let result = execute(argv, ops, root, "", redactor, allow_remote)
  if ! result.stdout.is_empty() {
    io.write_stdout(result.stdout)?
  }

  if ! result.stderr.is_empty() {
    io.write_stderr(result.stderr)?
  }

  result.exit
}
