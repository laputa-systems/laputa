##! In-container seed smoke test: the mounted seed XSH runs, plans the repository, and passes PM suites offline.
#!/bin/xsh
# `seed.xsh smoke` runs this inside package-tools with `--network none`, the
# seed mounted at /bin and /usr/lib/xsh/core, and the checkout read-only at
# /src/laputa.

# The default suites need no Docker, privilege, or network, and cover the
# recipe, plan, graph, and store contracts the seed must execute.
const seed_smoke_default_suites = [
  "tests/pm/pm_recipe.xsh",
  "tests/pm/pm_plan.xsh",
  "tests/pm/pm_graph.xsh",
  "tests/pm/pm_store.xsh",
]

proc main(arch: Str, ...suites: List[Str]) [fs, process, env, error] {
  run /bin/xsh --startup
  run /bin/xsht --help
  run /bin/xsh --help

  let manifest = json.read(fp"/src/laputa/.out/seed/{arch}/manifest.json")?.require(Record)?
  let commit: Str = manifest.get("xsh_commit")?.require()?
  let dirty: Bool = manifest.get("xsh_dirty")?.require()?
  print f"seed xsh {commit} dirty={dirty}"

  tempdir handle {
    let plan = fp"{handle}/plan.json"
    run /bin/xsh /src/laputa/pm.xsh -- repo plan --repo /src/laputa --all --target f"{arch}-linux-musl" --output $plan
    print f"planned {json.read(plan)?.require(Record)?.get("nodes")?.require(List[Record])?.len()} nodes offline"

    for suite in if suites.is_empty() { seed_smoke_default_suites } else { suites } {
      run /bin/xsht test $suite
    }
  }
}

main(@args)
