##! Benchmark selection contracts.
## A selectable workload.
export type Workload = {name: Str, tier: Int, area: Str, purpose: Str, cost: Str, argv: List[Str], requires: List[Path], tools: List[Str]}

## List available workloads.
export pure workloads(xsht: Str) -> List[Workload] {
  [
    {name: "selection", tier: 0, area: "harness", purpose: "selection contracts", cost: "estimated seconds", argv: [xsht, "test", "tests/bench/test_bench.xsh"], requires: [fp"{xsht}", p"tests/bench/test_bench.xsh"], tools: []},
    {name: "pm-catalog", tier: 1, area: "pm", purpose: "validate the real package catalog", cost: "estimated seconds", argv: [xsht.replace("/xsht", with: "/xsh"), "bench/catalog.xsh"], requires: [fp"{xsht.replace("/xsht", with: "/xsh")}", p"bench/catalog.xsh", p"packages"], tools: []},
    {name: "pm-check", tier: 1, area: "pm", purpose: "type-check production package manager", cost: "estimated seconds", argv: [xsht, "check", "pm"], requires: [fp"{xsht}", p"pm"], tools: []},
    {name: "make-graph", tier: 1, area: "build", purpose: "checked build graph execution and reuse", cost: "estimated seconds", argv: [xsht, "test", "test_pyramid_kernel_graph"], requires: [fp"{xsht}", p"packages/linux/tests/pyramid.xsh"], tools: []},
    {name: "tree-memory", tier: 2, area: "memory", purpose: "measure container-tree peak for an offline package plan", cost: "estimated minutes", argv: ["bash", "bench/support.sh", "workload", "tree-memory"], requires: [p".out/seed/x86_64/manifest.json", p"bench/support.sh"], tools: ["docker", "bash", "jaq", "git", "sha256sum"]},
    {name: "artifact-sizes", tier: 2, area: "size", purpose: "measure seed package and image bytes", cost: "estimated minutes", argv: ["bash", "bench/support.sh", "workload", "artifact-sizes"], requires: [p".out/seed/x86_64/manifest.json", p"bench/support.sh"], tools: ["docker", "bash", "jaq", "git", "sha256sum"]},
    {name: "world-plan", tier: 2, area: "pm", purpose: "checked offline world plan time", cost: "estimated minutes", argv: ["bash", "bench/support.sh", "workload", "world-plan"], requires: [p"bench/support.sh"], tools: ["docker", "bash", "jaq", "git", "sha256sum"]},
    {name: "warm-rebuild", tier: 2, area: "build", purpose: "checked warm baselayout closure rebuild", cost: "estimated minutes", argv: ["bash", "bench/support.sh", "workload", "warm-rebuild"], requires: [p"bench/support.sh"], tools: ["docker", "bash", "jaq", "git", "sha256sum"]},
    {name: "root-compose", tier: 2, area: "pm", purpose: "checked baselayout root composition", cost: "estimated minutes", argv: ["bash", "bench/support.sh", "workload", "root-compose"], requires: [p"bench/support.sh"], tools: ["docker", "bash", "jaq", "git", "sha256sum"]},
    {name: "mirror-publish", tier: 2, area: "mirror", purpose: "publish and verify a plan through a private mirror", cost: "estimated minutes", argv: ["bash", "bench/support.sh", "workload", "mirror-publish"], requires: [p"bench/scenario.py"], tools: ["docker", "bash", "python3", "jaq", "git", "sha256sum"]},
    {name: "profile-ready", tier: 2, area: "system", purpose: "boot to the profile readiness marker", cost: "estimated minutes", argv: ["bash", "bench/support.sh", "workload", "profile-ready"], requires: [p"bench/scenario.py", p"bench/profile_argv.xsh"], tools: ["python3", "qemu-system-x86_64"]},
    {name: "xinit-service-start", tier: 2, area: "xinit", purpose: "start a supervised notify service", cost: "estimated minutes", argv: ["bash", "bench/support.sh", "workload", "xinit-service-start"], requires: [p"bench/scenario.py"], tools: ["docker", "python3"]},
    {name: "package-build", tier: 3, area: "build", purpose: "build baselayout and its closure", cost: "estimated hours", argv: ["make", "build", "PKGS=baselayout"], requires: [p"packages/baselayout/PKGBUILD.xsh", p".out/seed/x86_64/manifest.json"], tools: ["make", "docker"]},
    {name: "mirror-build", tier: 3, area: "mirror", purpose: "build the mirror", cost: "estimated minutes", argv: ["make", "mirror-build"], requires: [p"mirror/Cargo.lock"], tools: ["make", "cargo"]},
    {name: "installer-size", tier: 3, area: "installer", purpose: "report x86_64 installer and package sizes", cost: "estimated seconds", argv: [xsht.replace("/xsht", with: "/xsh"), "installer-size.xsh", "--", "x86_64"], requires: [fp"{xsht.replace("/xsht", with: "/xsh")}", p"installer-size.xsh", p"target/laputa-installer-x86_64/laputa-installer-x86_64.iso", p"target/laputa-installer-x86_64/laputa-installer-x86_64.vmlinuz", p"target/laputa-installer-x86_64/rootfs-target", p"target/laputa-installer-x86_64/rootfs-installer"], tools: []},
    {name: "profile-boot", tier: 3, area: "system", purpose: "boot and check the usable profile", cost: "estimated hours", argv: ["make", "profile-test"], requires: [p"profiles/qemu-tinyland-ghostty.xsh"], tools: ["make", "docker", "qemu-system-x86_64"]},
  ]
}

pure tier_value(tier: Str) -> Result[Int] {
  return Ok(0) when tier == "edit"
  return Ok(1) when tier == "change"
  return Ok(2) when tier == "scenario"
  return Ok(3) when tier == "full"
  fail f"unknown tier {tier}"
}

## Render a registered tier.
export pure tier_name(tier: Int) -> Str {
  return "edit" when tier == 0
  return "change" when tier == 1
  return "scenario" when tier == 2
  "full"
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
  let selected = [item for item in all if item.tier <= ceiling and (names.is_empty() or item.name in names) and (areas.is_empty() or item.area in areas) and !(item.name in skip)]
  fail "empty workload selection" when selected.is_empty()
  selected
}
