##! Versioned saved-plan artifacts and stale-observation checks.

use xinfra.model
use xinfra.outcome
use xinfra.plan
use xinfra.validate
use xinfra.version

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

## Saves a plan after rejecting unknown actions.
export proc save_plan(
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

## Loads a plan with the exact supported schema.
export proc load_plan(target: Path) [fs, error] -> Result[PlanArtifact, model.Problem] {
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

## Rejects a plan whose inputs or observations have changed.
export proc check_plan(
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
