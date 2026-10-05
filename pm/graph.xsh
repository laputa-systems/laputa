##! Deterministic typed dependency graph resolution.
use policy
use types

pure graph_sorted_unique_names(names: List[Str]) -> List[Str] {
  var seen: Map[Bool] = {}

  let unique: List[Str] = collect {
    for name in names |> sort {
      if ! (seen.get(name) ?? false) {
        yield name
        seen[name] = true
      }
    }
  }

  unique
}

pure kind_is_selected(kind: types.DependencyKind, kinds: List[types.DependencyKind]) -> Bool {
  kind in kinds
}

## Returns whether an edge names a build input of its dependent: one whose artifact the
## dependent's build root holds, so it must be built first and its key enters the
## dependent's artifact key.
export pure edge_orders_builds(kind: types.DependencyKind) -> Bool {
  kind != types.dependency_bootstrap() and kind != types.dependency_runtime_only()
}

pure edge_key(from: Str, to: Str) -> Str {
  f"{from}->{to}"
}

pure package_edges(pkg: types.Package, value: types.BuildPolicy) -> List[types.DependencyEdge] {
  var result: List[types.DependencyEdge] = []

  for dependency in pkg.deps {
    let kind = if policy.is_bootstrap_dependency(value, pkg.name, dependency) {
      types.dependency_bootstrap()
    } else {
      types.dependency_runtime()
    }
    result += [{from: pkg.name, to: dependency, kind}]
  }

  # Bootstrap seeds substitute build inputs; a runtime-only edge is never one.
  for dependency in pkg.runtime_only_deps {
    result += [{from: pkg.name, to: dependency, kind: types.dependency_runtime_only()}]
  }

  for dependency in pkg.mkdeps_host {
    let kind = if policy.is_bootstrap_dependency(value, pkg.name, dependency) {
      types.dependency_bootstrap()
    } else {
      types.dependency_build_host()
    }
    result += [{from: pkg.name, to: dependency, kind}]
  }

  for dependency in pkg.mkdeps_target {
    let kind = if policy.is_bootstrap_dependency(value, pkg.name, dependency) {
      types.dependency_bootstrap()
    } else {
      types.dependency_build_target()
    }
    result += [{from: pkg.name, to: dependency, kind}]
  }

  result
}

pure selected_edges(
  dependency_edges: List[types.DependencyEdge],
  kinds: List[types.DependencyKind],
) -> List[types.DependencyEdge] {
  [edge for edge in dependency_edges if kind_is_selected(edge.kind, kinds)]
}

pure direct_dependencies(name: Str, dependency_edges: List[types.DependencyEdge]) -> List[Str] {
  graph_sorted_unique_names([edge.to for edge in dependency_edges if edge.from == name])
}

pure index_in_path(trail: List[Str], name: Str) -> Int {
  var index = 0

  while index < trail.len() {
    return index when trail[index] == name

    index += 1
  }

  -1
}

pure cycle_from(
  name: Str,
  selected: Map[Bool],
  dependency_edges: List[types.DependencyEdge],
  trail: List[Str],
) -> List[Str] {
  for dependency in direct_dependencies(name, dependency_edges) {
    continue unless selected.get(dependency) ?? false
    let cycle_index = index_in_path(trail, dependency)

    if cycle_index >= 0 {
      var index = cycle_index

      let cycle: List[Str] = collect {
        while index < trail.len() {
          yield trail[index]
          index += 1
        }
      }

      return cycle.push(dependency)
    }

    let nested = cycle_from(dependency, selected, dependency_edges, trail.push(dependency))

    return nested when ! nested.is_empty()
  }

  []
}

pure find_cycle(selected_names: List[Str], dependency_edges: List[types.DependencyEdge]) -> List[Str] {
  let selected = {name: true for name in selected_names}

  for name in selected_names {
    let cycle = cycle_from(name, selected, dependency_edges, [name])

    return cycle when ! cycle.is_empty()
  }

  []
}

proc closure_from_edges(
  catalog: types.PackageCatalog,
  roots: List[Str],
  kinds: List[types.DependencyKind],
  dependency_edges: List[types.DependencyEdge],
) [error] -> Result[List[Str]] {
  let local_names = {pkg.name: true for pkg in catalog.packages}
  let remote_names = {name: true for name in catalog.remote_names}
  let kind_edges = selected_edges(dependency_edges, kinds)
  var pending = graph_sorted_unique_names(roots)
  var included: Map[Bool] = {}
  var index = 0

  while index < pending.len() {
    let name = pending[index]

    if ! (local_names.get(name) ?? false) and ! (remote_names.get(name) ?? false) {
      return Err(types.PmError.MissingDependency(f"graph root {name} is unavailable"))
    }

    if ! (included.get(name) ?? false) {
      included[name] = true

      for dependency in direct_dependencies(name, kind_edges) {
        if ! (included.get(dependency) ?? false) {
          pending += [dependency]
        }
      }
    }

    index += 1
  }

  graph_sorted_unique_names([name for name in pending if included.get(name) ?? false])
}

## Classifies every declared and policy-seeded dependency edge in a catalog.
export proc edges(
  catalog: types.PackageCatalog,
  value: types.BuildPolicy,
) [error] -> Result[List[types.DependencyEdge], Error] {
  let local_names = {pkg.name: true for pkg in catalog.packages}
  let remote_names = {name: true for name in catalog.remote_names}
  var declared_pairs: Map[Bool] = {}

  let result: List[types.DependencyEdge] = collect {
    for pkg in catalog.packages {
      for edge in package_edges(pkg, value) {
        yield edge
        declared_pairs[edge_key(edge.from, edge.to)] = true
      }
    }

    for rule in value.bootstrap_seeds {
      continue unless (! rule.native_only or value.native_build) and (local_names.get(rule.package) ?? false)

      if ! (local_names.get(rule.dependency) ?? false) and ! (remote_names.get(rule.dependency) ?? false) {
        return Err(types.PmError.MissingDependency(f"{rule.package} bootstrap requires missing {rule.dependency}"))
      }

      let key = edge_key(rule.package, rule.dependency)

      if ! (declared_pairs.get(key) ?? false) {
        yield {from: rule.package, to: rule.dependency, kind: types.dependency_bootstrap()}
      }
    }
  }

  result
}

## Resolves a deterministic dependency closure for selected edge kinds under the default build policy.
export proc closure(
  catalog: types.PackageCatalog,
  roots: List[Str],
  kinds: List[types.DependencyKind],
) [error] -> Result[List[Str], Error] {
  closure_from_edges(catalog, roots, kinds, edges(catalog, policy.aarch64_docker())?)?
}

## Produces dependency-first lexical topological levels. Bootstrap seed edges are externally
## provided, and runtime-only edges are not build inputs, so neither orders local builds; a
## runtime-only dependency may therefore build after its dependent, or close a cycle.
export proc topological_levels(
  selected: List[Str],
  dependency_edges: List[types.DependencyEdge],
) [error] -> Result[List[List[Str]], Error] {
  let selected_names = graph_sorted_unique_names(selected)
  let selected_map = {name: true for name in selected_names}
  let local_edges = [
    edge
    for edge in dependency_edges
    if edge_orders_builds(edge.kind) and (selected_map.get(edge.from) ?? false) and (selected_map.get(edge.to) ?? false)
  ]
  var unresolved: Map[Int] = {}
  var emitted: Map[Bool] = {}
  for name in selected_names {
    unresolved[name] = 0
  }

  for edge in local_edges {
    unresolved[edge.from] = (unresolved.get(edge.from) ?? 0) + 1
  }

  var emitted_count = 0

  let levels: List[List[Str]] = collect {
    while emitted_count < selected_names.len() {
      var ready = [
        name
        for name in selected_names
        if ! (emitted.get(name) ?? false) and (unresolved.get(name) ?? 0) == 0
      ]
      if ready.is_empty() {
        let cycle = find_cycle(selected_names, local_edges)
        let rendered = if ! cycle.is_empty() { cycle.join(" -> ") } else { selected_names.join(", ") }
        return Err(types.PmError.DependencyCycle(f"package dependency cycle: {rendered}"))
      }

      yield ready

      for name in ready {
        emitted[name] = true
        emitted_count += 1

        for edge in local_edges {
          if edge.to == name {
            unresolved[edge.from] = (unresolved.get(edge.from) ?? 0) - 1
          }
        }
      }
    }
  }

  levels
}

## Resolves runtime and runtime-only dependencies, excluding host and target build dependencies.
export proc runtime_closure(catalog: types.PackageCatalog, roots: List[Str]) [error] -> Result[List[Str], Error] {
  closure(catalog, roots, [types.dependency_runtime(), types.dependency_runtime_only()])?
}

# A bootstrap edge names a build input the seed substitutes (the container's
# LLVM for musl), so it selects nothing: a plan for musl must not pull in zlib
# and, through zlib, cmake.
pure build_closure_kinds() -> List[types.DependencyKind] {
  [
    types.dependency_runtime(),
    types.dependency_runtime_only(),
    types.dependency_build_host(),
    types.dependency_build_target(),
  ]
}

## Resolves every package a plan for the selected roots must produce: their build inputs
## (runtime, host-build, and target-build edges) and the runtime-only dependencies root
## composition installs beside them. Bootstrap edges select no package.
export proc build_closure(
  catalog: types.PackageCatalog,
  roots: List[Str],
  value: types.BuildPolicy,
) [error] -> Result[List[Str], Error] {
  closure_from_edges(catalog, roots, build_closure_kinds(), edges(catalog, value)?)?
}

## Returns, in name order, every local package whose `build_closure` contains none of
## `excluded`: the packages a plan can produce before any excluded package exists.
## The macOS bootstrap stops before `cmake` and `linux` with this selection.
export proc packages_buildable_without(
  catalog: types.PackageCatalog,
  excluded: List[Str],
  value: types.BuildPolicy,
) [error] -> Result[List[Str], Error] {
  let local_names = {pkg.name: true for pkg in catalog.packages}

  for name in excluded {
    guard local_names.get(name) ?? false else {
      return Err(types.PmError.MissingDependency(f"excluded package {name} is not in the catalog"))
    }
  }

  let dependency_edges = edges(catalog, value)?
  let selected: List[Str] = collect {
    for pkg in catalog.packages {
      let package_closure = closure_from_edges(catalog, [pkg.name], build_closure_kinds(), dependency_edges)?

      yield pkg.name when [name for name in package_closure if name in excluded].is_empty()
    }
  }

  graph_sorted_unique_names(selected)
}
