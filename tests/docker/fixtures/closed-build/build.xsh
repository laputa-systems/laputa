use pm.catalog
use pm.execute
use pm.plan
use pm.policy
use pm.types

proc main(repository: Path) [fs, net, process, env, time, error] {
  let snapshot: types.RemoteSnapshot = {target: types.target_x86_64(), index_sha256: "closed-cohort", packages: []}
  let value = plan.resolve(catalog.load(repository)?, snapshot, policy.x86_64_docker(), ["cohort-c", "cohort-rust", "cohort-xsh"], false)?
  let result = execute.build_plan(value, repository, /output/store, "", 1)?
  assert result.artifacts.len() == 3
  print "closed cohort published"
}

main(@args)?
