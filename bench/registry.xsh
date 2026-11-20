##! Benchmark selection contracts.
## A selectable workload.
export type Workload = {name: Str, tier: Int, area: Str, purpose: Str, cost: Str, argv: List[Str]}

## List available workloads.
export pure workloads(xsht: Str) -> List[Workload] {
  [
    {name: "selection", tier: 0, area: "harness", purpose: "selection contracts", cost: "estimated seconds", argv: [xsht, "test", "tests/bench/test_bench.xsh"]},
    {name: "pm-catalog", tier: 1, area: "pm", purpose: "validate the real package catalog", cost: "estimated seconds", argv: [xsht.replace("/xsht", with: "/xsh"), "bench/catalog.xsh"]},
    {name: "pm-check", tier: 1, area: "pm", purpose: "type-check production package manager", cost: "estimated seconds", argv: [xsht, "check", "pm"]},
    {name: "make-graph", tier: 1, area: "build", purpose: "checked build graph execution and reuse", cost: "estimated seconds", argv: [xsht, "test", "test_pyramid_kernel_graph"]},
  ]
}

pure tier_value(tier: Str) -> Result[Int] {
  if tier == "edit" { return Ok(0) }
  if tier == "change" { return Ok(1) }
  if tier == "scenario" { return Ok(2) }
  if tier == "full" { return Ok(3) }
  fail f"unknown tier {tier}"
}

## Select workloads or report invalid selectors.
export pure select(all: List[Workload], tier: Str, names: List[Str], areas: List[Str], skip: List[Str], full: Bool) -> Result[List[Workload], Error] {
  let ceiling = tier_value(tier)?
  fail "full tier requires FULL=1" when ceiling == 3 and !full
  for name in names + skip {
    fail f"unknown workload {name}" when name not in [item.name for item in all]
  }
  for area in areas {
    fail f"unknown area {area}" when area not in [item.area for item in all]
  }
  let selected = [item for item in all if item.tier <= ceiling and (names.len() == 0 or item.name in names) and (areas.len() == 0 or item.area in areas) and !(item.name in skip)]
  fail "empty workload selection" when selected.len() == 0
  selected
}
