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
}
