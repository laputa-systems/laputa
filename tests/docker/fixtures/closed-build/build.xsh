use pm.catalog
use pm.execute
use pm.plan
use pm.policy
use pm.types

proc assert_no_substrate_leftovers() [fs, error] {
  let leftovers = fs.walk(p"/scratch", hidden: true)
    |> where .name == "build-root"
    |> map .path
    |> collect()
  assert leftovers.is_empty(), f"confined build left {leftovers.len()} build roots beneath /scratch"
}

## Resolves and builds the closed cohort, running every package build child
## through the cohort confinement profile. `mode` selects the honest cohort, or
## one hostile package that must fail under confinement.
proc main(repository: Path, mode: Str = "cohort") [fs, net, process, env, time, error] {
  let hostiles: Map[Path] = {
    "cohort-hostile-read": p"cohort-hostile-read",
    "cohort-hostile-write": p"cohort-hostile-write",
    "cohort-hostile-tcp": p"cohort-hostile-tcp",
  }
  let honest = ["cohort-c", "cohort-rust", "cohort-xsh"]

  if mode in hostiles {
    let source = hostiles.get(mode)?
    let hostile_repository = fp"/cohort/{source.display()}"
    let snapshot: types.RemoteSnapshot = {target: types.target_x86_64(), index_sha256: "closed-hostile", packages: []}
    let value = plan.resolve(catalog.load(hostile_repository)?, snapshot, policy.x86_64_docker(), [mode], false)?
    let _ = execute.build_plan(
      value,
      hostile_repository,
      p"/output/store",
      "",
      1,
      confinement: policy.closed_build_confinement(p"/scratch"),
    )?
    print f"hostile cohort {mode} published"
    return
  }

  let snapshot: types.RemoteSnapshot = {target: types.target_x86_64(), index_sha256: "closed-cohort", packages: []}
  let value = plan.resolve(catalog.load(repository)?, snapshot, policy.x86_64_docker(), honest, false)?
  let result = execute.build_plan(
    value,
    repository,
    p"/output/store",
    "",
    1,
    confinement: policy.closed_build_confinement(p"/scratch"),
  )?
  assert_no_substrate_leftovers()?
  assert result.artifacts.len() == 3
  print "closed cohort published"
}

main(@args)?
