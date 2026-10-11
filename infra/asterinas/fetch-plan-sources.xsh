##! Fetch the source inputs named by one exact PM build plan.
use pm.cli as pm_cli
use pm.plan_json as pm_plan_json
use pm.types as pm_types

proc main(plan_path: Path) [fs, net, process, env, time, error] {
  let plan = pm_plan_json.read(plan_path)?
  let packages = [node.name for node in plan.nodes]
  let args = [
    "sources",
    "fetch",
    "--repo",
    fs.cwd()?.display(),
    "--target",
    pm_types.target_text(plan.target),
  ].extend(packages)

  pm_cli.run_pm_cli(args)
}
