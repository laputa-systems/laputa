##! Saved-plan artifact and stale-observation matrix.

use xinfra.model
use xinfra.plan
use xinfra.plan_artifact as artifact
use xinfra.validate

proc require(condition: Bool, message: Str) -> Result[Unit, Error] {
  if condition { Ok() } else { Err(error.failure(message)) }
}

pure rejected(result: Result[Unit, model.Problem]) -> Bool {
  match result { Ok(_) => false, Err(_) => true }
}

## Executes the saved-plan matrix.
export proc check_plans() [fs, env, error] -> Result[Unit, Error] {
  let root = fs.tempdir()?
  let target = fp"{root.host_path()?}/plan.json"
  let deployment_file = fp"{root.host_path()?}/deploy.xsh"
  let inventory_file = fp"{root.host_path()?}/inventory.toml"
  deployment_file.write("deployment")?
  inventory_file.write("inventory")?
  let sources: Map[Str, validate.PreparedSource] = map.empty()
    .set("file", validate.Content(validate.ContentSource(text: "canary-value", digest: "digest-one")))
    .set("secret", validate.Secret(model.FromEnv("PLAN_SECRET")))
  let deployment = validate.Deployment(file: deployment_file, root: root.host_path()?, resources: [], sources: sources)
  let facts = plan.Facts(hosts: [plan.HostFacts(name: "xinfra-a", observed: map.empty().set("file", plan.Absent))])
  let action = plan.Action(id: "file", host: "xinfra-a", resource: model.Directory(model.DirectorySpec(id: "file", path: p"/file")), operation: plan.EnsureDirectory, prediction: plan.Changed)
  let actions = [action]
  env ({XSH_PIN: "pin-one", PLAN_SECRET: "canary-value"}) {
    match artifact.save_plan(target, "run-1", deployment_file, inventory_file, deployment, facts, actions) {
      Ok(_) => {}, Err(failure) => { return Err(error.failure(failure.message)) },
    }
    let loaded = match artifact.load_plan(target) {
      Ok(value) => value, Err(failure) => { return Err(error.failure(failure.message)) },
    }
    require(loaded.run_id == "run-1" and loaded.actions.len() == 1, "artifact did not round-trip")?
    require("canary-value" not in target.read_text()?, "saved plan contains a canary")?
    require(! rejected(artifact.check_plan(loaded, deployment_file, inventory_file, deployment, facts, actions, "pin-one")), "matching artifact was stale")?
    require(rejected(artifact.check_plan(loaded, deployment_file, inventory_file, deployment, facts, actions, "pin-two")), "pin was not checked")?
    let changed_facts = plan.Facts(hosts: [plan.HostFacts(name: "xinfra-a", observed: map.empty().set("file", plan.Unknown))])
    require(rejected(artifact.check_plan(loaded, deployment_file, inventory_file, deployment, changed_facts, actions, "pin-one")), "observations were not checked")?
    require(rejected(artifact.check_plan(loaded, deployment_file, inventory_file, deployment, facts, [], "pin-one")), "actions were not checked")?
    let changed_sources = sources.set("file", validate.Content(validate.ContentSource(text: "changed", digest: "digest-two")))
    let changed_deployment = {...deployment, sources: changed_sources}
    require(rejected(artifact.check_plan(loaded, deployment_file, inventory_file, changed_deployment, facts, actions, "pin-one")), "source was not checked")?
    require(rejected(artifact.check_plan({...loaded, version: "other"}, deployment_file, inventory_file, deployment, facts, actions, "pin-one")), "version was not checked")?
    inventory_file.write("changed")?
    require(rejected(artifact.check_plan(loaded, deployment_file, inventory_file, deployment, facts, actions, "pin-one")), "inventory was not checked")?
    inventory_file.write("inventory")?
    deployment_file.write("changed")?
    require(rejected(artifact.check_plan(loaded, deployment_file, inventory_file, deployment, facts, actions, "pin-one")), "deployment was not checked")?
    let serialized = target.read_text()?
    target.write(serialized.replace("\"schema_version\": 1", with: "\"schema_version\": 2"))?
    require(match artifact.load_plan(target) { Ok(_) => false, Err(_) => true }, "unsupported version was accepted")?
    target.write(serialized.replace("\"kind\": \"plan\"", with: "\"kind\": \"other\""))?
    require(match artifact.load_plan(target) { Ok(_) => false, Err(_) => true }, "unsupported kind was accepted")?
    target.write(serialized.replace("\"kind\": \"plan\"", with: "\"extra\": 1, \"kind\": \"plan\""))?
    require(match artifact.load_plan(target) { Ok(_) => false, Err(_) => true }, "extra field was accepted")?
    target.write("{}")?
    require(match artifact.load_plan(target) { Ok(_) => false, Err(_) => true }, "invalid schema was accepted")?
  }
  print "ok saved-plan round-trip and stale checks"
  Ok()
}
