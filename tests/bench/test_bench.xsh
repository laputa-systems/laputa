use bench.registry

test test_bench_selection [error] {
  let all = registry.workloads("xsht")
  let edit = registry.select(all, "edit", [], [], [], false)?
  let pm = registry.select(all, "change", [], ["pm"], [], false)?
  let graph = registry.select(all, "change", ["make-graph"], [], [], false)?
  assert [w.name for w in edit] == ["selection"]
  assert [w.name for w in pm] == ["pm-catalog", "pm-check"]
  assert [w.name for w in graph] == ["make-graph"]
  assert registry.select(all, "change", ["unknown"], [], [], false) is Err(_)
  assert registry.select(all, "change", [], ["unknown"], [], false) is Err(_)
  assert registry.select(all, "edit", ["pm-catalog"], [], [], false) is Err(_)
  assert registry.select(all, "edit", [], [], ["selection"], false) is Err(_)
  assert registry.select(all, "full", [], [], [], false) is Err(_)
  let scenario = registry.select(all, "scenario", ["world-plan"], [], [], false)?
  let full = registry.select(all, "full", [], [], [], true)?
  assert [w.name for w in scenario] == ["world-plan"]
  assert [w.name for w in full if w.tier == 3] == ["package-build", "mirror-build", "installer-size", "profile-boot"]
  assert registry.select(all, "change", ["world-plan"], [], [], false) is Err(_)
  assert [registry.tier_name(n) for n in [0, 1, 2, 3]] == ["edit", "change", "scenario", "full"]
}
