##! Versioned saved-plan artifacts and stale-observation checks.

## One approved action in a saved plan.
export type Entry = {
  id: Str,
  host: Str,
  operation: Str,
  observed: Str? = null,
}

## One observed prerequisite.
export type Observation = {key: Str, value: Str}

## A version-1 saved plan with its pins and observed prerequisites.
export type Artifact = {
  schema_version: Int,
  kind: Str,
  run_id: Str,
  deployment_digest: Str,
  inventory_digest: Str,
  source_digest: Str,
  xsh_pin: Str,
  observations: List[Observation],
  actions: List[Entry],
}

## Build one artifact.
export pure build(
  run_id: Str,
  deployment_digest: Str,
  inventory_digest: Str,
  source_digest: Str,
  xsh_pin: Str,
  observations: List[Observation],
  actions: List[Entry],
) -> Artifact {
  Artifact(
    schema_version: 1,
    kind: "plan",
    run_id: run_id,
    deployment_digest: deployment_digest,
    inventory_digest: inventory_digest,
    source_digest: source_digest,
    xsh_pin: xsh_pin,
    observations: observations,
    actions: actions,
  )
}

## Whether every action is safe to approve in a saved plan.
export pure allows_save(actions: List[Entry]) -> Bool {
  for action in actions {
    if action.operation == "unknown" or action.operation == "conditional" {
      return false
    }
  }
  true
}

## Why an artifact is stale, or null when it still matches.
export pure stale(
  artifact: Artifact,
  deployment_digest: Str,
  inventory_digest: Str,
  source_digest: Str,
  xsh_pin: Str,
  observations: List[Observation],
  actions: List[Entry],
) -> Str? {
  return "deployment" when artifact.deployment_digest != deployment_digest
  return "inventory" when artifact.inventory_digest != inventory_digest
  return "source" when artifact.source_digest != source_digest
  return "pin" when artifact.xsh_pin != xsh_pin
  return "observations" when artifact.observations != observations
  return "actions" when artifact.actions != actions
  null
}

## Write one artifact as JSON.
export proc save(target: Path, artifact: Artifact) [fs, error] -> Result[Unit, Error] {
  json.write(target, artifact, pretty: true)
}

## Load one artifact, requiring the exact schema.
export proc load(target: Path) [fs, error] -> Result[Artifact, Error] {
  let raw = json.read(target)?
  raw.require_exact(Artifact)
}

## Whether text contains a known secret.
export pure contains_secret(text: Str, secret: Str) -> Bool {
  secret in text
}
