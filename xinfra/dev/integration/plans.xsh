##! Saved-plan artifact and stale-observation matrix.

use xinfra.plan_artifact as artifact

proc require(condition: Bool, message: Str) -> Result[Unit, Error] {
  if condition { Ok() } else { Err(error.failure(message)) }
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the saved-plan matrix.
export proc check_plans() [fs, error] -> Result[Unit, Error] {
  let root = match fs.tempdir() {
    Ok(value) => value,
    Err(error) => { return Err(error) },
  }
  let target = fp"{root.host_path()?}/plan.json"
  let observations = [artifact.Observation(key: "xinfra-a/file", value: "digest-one")]
  let actions = [
    artifact.Entry(id: "file", host: "xinfra-a", operation: "ensure_file", observed: "digest-one"),
  ]
  let built = artifact.build(
    "run-1",
    "deployment-one",
    "inventory-one",
    "source-one",
    "pin-one",
    observations,
    actions,
  )
  artifact.save(target, built)?
  let loaded = artifact.load(target)?
  require(loaded.run_id == "run-1", "run id did not round-trip")?
  require(loaded.deployment_digest == "deployment-one", "deployment digest did not round-trip")?
  require(loaded.actions == actions, "actions did not round-trip")?
  require(loaded.observations == observations, "observations did not round-trip")?
  print test_case("save and load round-trip")

  require(
    artifact.stale(loaded, "deployment-one", "inventory-one", "source-one", "pin-one", observations, actions) == null,
    "matching artifact was stale",
  )?
  require(
    artifact.stale(loaded, "deployment-two", "inventory-one", "source-one", "pin-one", observations, actions) == "deployment",
    "deployment digest was not checked",
  )?
  require(
    artifact.stale(loaded, "deployment-one", "inventory-two", "source-one", "pin-one", observations, actions) == "inventory",
    "inventory digest was not checked",
  )?
  require(
    artifact.stale(loaded, "deployment-one", "inventory-one", "source-two", "pin-one", observations, actions) == "source",
    "source digest was not checked",
  )?
  require(
    artifact.stale(loaded, "deployment-one", "inventory-one", "source-one", "pin-two", observations, actions) == "pin",
    "pin was not checked",
  )?
  let changed_observations = [artifact.Observation(key: "xinfra-a/file", value: "digest-two")]
  require(
    artifact.stale(loaded, "deployment-one", "inventory-one", "source-one", "pin-one", changed_observations, actions) == "observations",
    "observations were not checked",
  )?
  let changed_actions = [
    artifact.Entry(id: "file", host: "xinfra-a", operation: "ensure_file", observed: "digest-two"),
    artifact.Entry(id: "extra", host: "xinfra-a", operation: "ensure_file"),
  ]
  require(
    artifact.stale(loaded, "deployment-one", "inventory-one", "source-one", "pin-one", observations, changed_actions) == "actions",
    "a stale approval was allowed to grow",
  )?
  print test_case("stale deployment, inventory, source, pin, observations, and actions")

  require(artifact.allows_save(actions), "valid actions were refused")?
  require(! artifact.allows_save([artifact.Entry(id: "x", host: "xinfra-a", operation: "unknown")]), "unknown action was savable")?
  require(! artifact.allows_save([artifact.Entry(id: "x", host: "xinfra-a", operation: "conditional")]), "conditional action was savable")?
  print test_case("conditional and unknown actions cannot be saved")

  let text_value = target.read_text()?
  require(! artifact.contains_secret(text_value, "canary-value"), "saved plan contains a canary")?
  print test_case("saved plan carries no secret")

  Ok()
}
