##! Behavior coverage for typed package catalog and dependency graph resolution.
use pm.catalog
use pm.graph
use pm.policy
use pm.types

pure fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/{name}"
}

pure has_edge(edges: List[types.DependencyEdge], from: Str, to: Str, kind: types.DependencyKind) -> Bool {
  for edge in edges {
    if edge.from == from and edge.to == to and edge.kind == kind {
      return true
    }
  }

  false
}

pure fixture_package(
  name: Str,
  deps: List[Str],
  mkdeps_host: List[Str],
  mkdeps_target: List[Str],
  runtime_only_deps: List[Str] = [],
) -> types.Package {
  {
    dir: fp"packages/{name}",
    name,
    ver: "1",
    rel: "1",
    kind: types.Meta,
    deps,
    runtime_only_deps,
    mkdeps_host,
    mkdeps_target,
    upstream_sources: [],
    filetree: [],
    nostrip: false,
    source_mirror: false,
  }
}

proc expect_catalog_rejection(root: Path, expected: Str) [fs, env, error] {
  match catalog.load(root) {
    Ok(_) => test.fail(f"{expected}: catalog unexpectedly loaded")?
    Err(problem) => assert expected in problem.message
  }
}

test test_catalog_loads_packages_in_name_order_with_relative_dirs [fs, env, error] {
  let value = catalog.load(fixture("graph-catalog"))?
  test.eq(catalog.package_names(value), ["app", "host-tool", "runtime-lib", "target-sdk"])?
  test.eq(value.packages[0].dir.display(), "packages/app")?
}

test test_catalog_rejects_missing_dependency [fs, env, error] {
  expect_catalog_rejection(fixture("graph-missing"), "app depends on missing missing")?
}

test test_catalog_rejects_duplicate_package_name [error] {
  let first = fixture_package("duplicate", [], [], [])
  let second = fixture_package("duplicate", [], [], [])

  match catalog.from_packages(p".", [first, second]) {
    Ok(_) => test.fail("duplicate package catalog unexpectedly loaded")?
    Err(problem) => assert "duplicate package duplicate" in problem.message
  }
}

test test_catalog_accepts_selected_remote_dependency_snapshot [error] {
  let app = fixture_package("app", ["remote-lib"], [], [])
  let value = catalog.from_packages(p".", [app], ["remote-lib"])?
  test.eq(value.remote_names, ["remote-lib"])?
}

test test_graph_classifies_runtime_and_build_edges [fs, env, error] {
  let value = catalog.load(fixture("graph-catalog"))?
  let edges = graph.edges(value, policy.aarch64_docker())?
  test.ok(has_edge(edges, "app", "runtime-lib", types.Runtime))?
  test.ok(has_edge(edges, "app", "host-tool", types.BuildHost))?
  test.ok(has_edge(edges, "app", "target-sdk", types.BuildTarget))?
}

test test_graph_classifies_each_explicit_bootstrap_seed [fs, env, error] {
  let value = catalog.load(p".")?
  let edges = graph.edges(value, policy.aarch64_docker())?
  test.ok(has_edge(edges, "musl", "llvm-toolchain", types.Bootstrap))?
  test.ok(has_edge(edges, "musl", "zlib", types.Bootstrap))?
  test.ok(has_edge(edges, "gnu-stubs", "llvm-toolchain", types.Bootstrap))?
}

test test_graph_reports_a_useful_cycle_path [fs, env, error] {
  let value = catalog.load(fixture("graph-cycle"))?
  let edges = graph.edges(value, policy.aarch64_docker())?

  match graph.topological_levels(catalog.package_names(value), edges) {
    Ok(_) => test.fail("cycle unexpectedly received levels")?
    Err(problem) => assert "alpha -> beta -> gamma -> alpha" in problem.message
  }
}

test test_graph_topological_levels_are_dependency_first [fs, env, error] {
  let value = catalog.load(fixture("graph-catalog"))?
  let edges = graph.edges(value, policy.aarch64_docker())?
  let levels = graph.topological_levels(catalog.package_names(value), edges)?
  test.eq(levels, [["host-tool", "runtime-lib", "target-sdk"], ["app"]])?
}

test test_runtime_closure_excludes_host_and_target_build_dependencies [fs, env, error] {
  let value = catalog.load(fixture("graph-catalog"))?
  let closure = graph.runtime_closure(value, ["app"])?
  test.eq(closure, ["app", "runtime-lib"])?
}

test test_build_closure_includes_runtime_host_and_target_edges [fs, env, error] {
  let value = catalog.load(fixture("graph-catalog"))?
  let closure = graph.build_closure(value, ["app"], policy.aarch64_docker())?
  test.eq(closure, ["app", "host-tool", "runtime-lib", "target-sdk"])?
}

test test_edge_kind_changes_the_appropriate_closure [error] {
  let dependency = fixture_package("dependency", [], [], [])
  let runtime_app = fixture_package("app", ["dependency"], [], [])
  let host_app = fixture_package("app", [], ["dependency"], [])
  let runtime_catalog = catalog.from_packages(p".", [runtime_app, dependency])?
  let host_catalog = catalog.from_packages(p".", [host_app, dependency])?
  test.eq(graph.runtime_closure(runtime_catalog, ["app"])?, ["app", "dependency"])?
  test.eq(graph.runtime_closure(host_catalog, ["app"])?, ["app"])?
  test.eq(graph.build_closure(host_catalog, ["app"], policy.aarch64_docker())?, ["app", "dependency"])?
}

test test_graph_resolution_is_repeatable [fs, env, error] {
  let first = catalog.load(fixture("graph-catalog"))?
  let second = catalog.load(fixture("graph-catalog"))?
  let value = policy.aarch64_docker()
  let first_edges = graph.edges(first, value)?
  let second_edges = graph.edges(second, value)?
  let first_levels = graph.topological_levels(catalog.package_names(first), first_edges)?
  let second_levels = graph.topological_levels(catalog.package_names(second), second_edges)?
  test.eq(catalog.package_names(first), catalog.package_names(second))?
  test.eq(first_edges, second_edges)?
  test.eq(first_levels, second_levels)?
  test.eq(graph.build_closure(first, ["app"], value)?, graph.build_closure(second, ["app"], value)?)?
}

# A runtime-only edge selects its target for runtime roots and for the plan
# that must produce them, but is no build input: it orders no build, so it
# may close a cycle with a build edge.
test test_runtime_only_edge_selects_closures_without_ordering_builds [error] {
  let runner = fixture_package("runner", [], [], [])
  let service = fixture_package("service", [], [], [], runtime_only_deps: ["runner"])
  let consumer = fixture_package("consumer", [], ["service"], [])
  let value = catalog.from_packages(p".", [runner, service, consumer])?
  let edges = graph.edges(value, policy.aarch64_docker())?
  test.ok(has_edge(edges, "service", "runner", types.RuntimeOnly))?
  test.eq(graph.runtime_closure(value, ["service"])?, ["runner", "service"])?
  test.eq(graph.build_closure(value, ["consumer"], policy.aarch64_docker())?, ["consumer", "runner", "service"])?
  test.eq(graph.topological_levels(["consumer", "runner", "service"], edges)?, [["runner", "service"], ["consumer"]])?

  let cyclic_runner = fixture_package("runner", ["service"], [], [])
  let cyclic = catalog.from_packages(p".", [cyclic_runner, service])?
  let cyclic_edges = graph.edges(cyclic, policy.aarch64_docker())?
  test.eq(graph.topological_levels(["runner", "service"], cyclic_edges)?, [["service"], ["runner"]])?
}

test test_catalog_rejects_missing_runtime_only_dependency [error] {
  let service = fixture_package("service", [], [], [], runtime_only_deps: ["absent"])

  match catalog.from_packages(p".", [service]) {
    Ok(_) => test.fail("missing runtime-only dependency unexpectedly loaded")?
    Err(problem) => assert "service depends on missing absent" in problem.message
  }
}

# A bootstrap edge names a build input the seed substitutes, so it selects
# nothing: planning the dependent must not pull in the seed's replacement.
test test_bootstrap_edge_selects_no_package [error] {
  let tool = fixture_package("tool", [], [], [])
  let replacement = fixture_package("replacement", [], ["tool"], [])
  let app = fixture_package("app", [], ["replacement"], [])
  let value = catalog.from_packages(p".", [tool, replacement, app])?
  let seeded = {
    ...policy.aarch64_docker(),
    bootstrap_seeds: [{package: "app", dependency: "replacement", native_only: false, reason: "seeded"}],
  }
  test.ok(has_edge(graph.edges(value, seeded)?, "app", "replacement", types.Bootstrap))?
  test.eq(graph.build_closure(value, ["app"], seeded)?, ["app"])?
  test.eq(graph.build_closure(value, ["app"], policy.aarch64_docker())?, ["app", "replacement", "tool"])?
}

test test_packages_buildable_without_drops_every_dependent_of_an_excluded_package [error] {
  let kernel = fixture_package("kernel", [], [], [])
  let builder = fixture_package("builder", [], [], [])
  let headers = fixture_package("headers", [], ["kernel"], [])
  let library = fixture_package("library", [], ["builder"], [])
  let runner = fixture_package("runner", [], [], [])
  let service = fixture_package("service", [], [], [], runtime_only_deps: ["headers"])
  let tool = fixture_package("tool", ["library"], [], [], runtime_only_deps: ["runner"])
  let value = catalog.from_packages(p".", [kernel, builder, headers, library, runner, service, tool])?
  let selected = graph.packages_buildable_without(value, ["kernel"], policy.aarch64_docker())?
  # A runtime-only edge counts: a plan for `service` must produce `headers`.
  test.eq(selected, ["builder", "library", "runner", "tool"])?
  test.eq(graph.packages_buildable_without(value, ["kernel", "builder"], policy.aarch64_docker())?, ["runner"])?

  match graph.packages_buildable_without(value, ["absent"], policy.aarch64_docker()) {
    Ok(_) => test.fail("an unknown excluded package was accepted")?
    Err(problem) => assert "excluded package absent is not in the catalog" in problem.message
  }
}
