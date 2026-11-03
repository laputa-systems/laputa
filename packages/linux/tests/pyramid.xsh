use packages.linux.kbuild
use pm.make
use pm.recipe
use pm.types
use packages.linux.kbuild_verify
use packages.linux.PKGBUILD-shared as linux_shared

error PyramidStopError = Failed(message: Str)

proc pyramid_plan_archives(plan: kbuild.KbuildPlan, cache: Path) [fs, process, env, time, error] -> Result[kbuild.BuiltinArchivePlan] {
  env ({XSH_LINUX_KBUILD_PLAN_CACHE_DIR: cache.display(), XSH_LINUX_KBUILD_COMPILE_FLAGS_CACHE_DIR: cache.display(),
    XSH_LINUX_KBUILD_TRUST_COMPILE_FLAGS_CACHE: "0"}) {
    return kbuild.plan_builtin_archives(plan, p"/usr/bin/cc", "x86_64-linux-gnu", [], [], [])?
  }
}

proc pyramid_kernel_source(ctx: TestContext) [fs, env, time, process, error] -> Result[Path] {
  let source = test.temp_dir(ctx, name: "pyramid-kernel")?
  fp"{source}/.config".write("CONFIG_TEST=y\n")
  fp"{source}/include/generated".mkdir()
  fp"{source}/include/generated/autoconf.h".write("#define CONFIG_TEST 1\n")
  fp"{source}/Kbuild".write("obj-y += main.o\n")
  fp"{source}/main.c".write("int main(void) { return 0; }\n")
  let discovered = kbuild.discover_plan(source, kbuild.load_config(fp"{source}/.config")?, "x86")?
  assert [item.display() for item in discovered.dirs] == ["."]
  assert [item.display() for item in discovered.objects] == ["main.o"]
  assert discovered.unsupported == []
  kbuild.write_discovered_plan(discovered, fp"{source}/.xsh-kbuild-plan.json")
  let cache = test.temp_dir(ctx, name: "pyramid-kbuild-cache")?
  cd (source) {
    let planned = pyramid_plan_archives(discovered, cache)?
    assert planned.missing_sources == []
    assert planned.generated_objects == []
    assert planned.task_count == 2
    kbuild.write_archive_plan_report(planned, p".xsh-kbuild-archive-plan.json")
  }
  source
}

proc pyramid_stop(stage: kbuild_verify.LinuxKbuildStop) [env, error] -> Result[Unit, Error] {
  let requested = kbuild_verify.linux_kbuild_stop_name(stage)
  env ({XSH_LINUX_KBUILD_STOP_AFTER: requested}) {
    linux_shared.stop_after(requested)
  }
}

proc pyramid_reject_stop(stage: kbuild_verify.LinuxKbuildStop, outcome: Result[Unit, Error], source: Path) [fs, error] {
  match kbuild_verify.linux_kbuild_verify_stopped(stage, outcome, source) {
    Ok(_) => test.fail("invalid kernel stop passed verification")
    Err(_) => {}
  }
}

test test_pyramid_kernel_stop_requires_exact_kind_and_stage [fs, env, time, process, error] { |ctx|
  let source = pyramid_kernel_source(ctx)?
  match kbuild_verify.linux_kbuild_verify_stopped(kbuild_verify.Prepare, Err(PyramidStopError.Failed("original cause")), source) {
    Err(PyramidStopError.Failed {message}) => assert message == "original cause"
    else => test.fail("kernel stop verification lost the original error family")
  }
  for stage in [kbuild_verify.Prepare, kbuild_verify.Discover, kbuild_verify.Plan] {
    kbuild_verify.linux_kbuild_verify_stopped(stage, pyramid_stop(stage), source)
    pyramid_reject_stop(stage, Ok(), source)
    pyramid_reject_stop(stage, Err(kbuild.ScriptError.Failed(kind: "compiler-failed", message: f"stopped after {kbuild_verify.linux_kbuild_stop_name(stage)}")), source)
    pyramid_reject_stop(stage, Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-stopped", message: "stopped after link")), source)
  }
}

test test_pyramid_kernel_stop_requires_stage_artifacts [fs, env, time, process, error] { |ctx|
  let source = pyramid_kernel_source(ctx)?
  let archive_report = fp"{source}/.xsh-kbuild-archive-plan.json"
  let planned = kbuild.read_archive_plan_report(archive_report)?
  kbuild.write_archive_plan_report({...planned, tasks: [], task_count: 0}, archive_report)
  pyramid_reject_stop(kbuild_verify.Plan, pyramid_stop(kbuild_verify.Plan), source)
  kbuild.write_archive_plan_report({...planned, missing_sources: [p"missing.c"]}, archive_report)
  pyramid_reject_stop(kbuild_verify.Plan, pyramid_stop(kbuild_verify.Plan), source)
  archive_report.remove()
  pyramid_reject_stop(kbuild_verify.Plan, pyramid_stop(kbuild_verify.Plan), source)
  kbuild_verify.linux_kbuild_verify_stopped(kbuild_verify.Discover, pyramid_stop(kbuild_verify.Discover), source)
  fp"{source}/.xsh-kbuild-plan.json".write("corrupt plan\n")
  pyramid_reject_stop(kbuild_verify.Discover, pyramid_stop(kbuild_verify.Discover), source)
  kbuild_verify.linux_kbuild_verify_stopped(kbuild_verify.Prepare, pyramid_stop(kbuild_verify.Prepare), source)
  fp"{source}/include/generated/autoconf.h".write("")
  pyramid_reject_stop(kbuild_verify.Prepare, pyramid_stop(kbuild_verify.Prepare), source)
  fp"{source}/include/generated/autoconf.h".remove()
  pyramid_reject_stop(kbuild_verify.Prepare, pyramid_stop(kbuild_verify.Prepare), source)
}

test test_pyramid_kernel_stop_preserves_mismatched_error_context_and_cause [fs, error] {
  for kind in ["compiler-failed", "linux-kbuild-stopped"] {
    let original: Result[Unit, Error] = Err(
      kbuild.ScriptError.Failed(kind:, message: "stopped after link"),
      cause: PyramidStopError.Failed("compiler input unavailable"),
    ).context("kernel-scenario", "requested preparation")
    let observed = kbuild_verify.linux_kbuild_verify_stopped(kbuild_verify.Prepare, original, p"missing-kernel-source")
    assert observed == original
  }
}


type PyramidKernelGraph = {source: Path, discovered: kbuild.KbuildPlan, directories: List[Str], objects: List[Path], objects_per_directory: Int}

proc pyramid_kernel_graph(
  ctx: TestContext,
  group_count: Int,
  objects_per_group: Int,
) [fs, env, time, error] -> Result[PyramidKernelGraph] {
  let source = test.temp_dir(ctx, name: f"pyramid-graph-{group_count}-{objects_per_group}")?
  fp"{source}/.config".write("CONFIG_TEST=y\n")
  let groups = [f"directory{index}" for index in range(group_count)]
  fp"{source}/Kbuild".write("obj-y += " + [f"{directory}/" for directory in groups].join(" ") + "\n")
  var objects: List[Path] = []
  for directory in groups {
    fp"{source}/{directory}".mkdir()
    let names = [f"unit{index}" for index in range(objects_per_group)]
    fp"{source}/{directory}/Kbuild".write("obj-y += " + [f"{name}.o" for name in names].join(" ") + "\n")
    for name in names {
      let input = fp"{source}/{directory}/{name}.c"
      input.write(f"int {directory}_{name}(void) {{ return 0; }}\n")
      fs.set_times(input, mtime_sec: 1)
      objects += [fp"{directory}/{name}.o"]
    }
  }
  let discovered = kbuild.discover_plan(source, kbuild.load_config(fp"{source}/.config")?, "x86")?
  assert [dir.display() for dir in discovered.dirs] == [".", @groups]
  assert discovered.objects == objects
  assert discovered.lib_objects == []
  assert discovered.composites == []
  assert discovered.unsupported == []
  {source, discovered, directories: groups, objects, objects_per_directory: objects_per_group}
}

proc pyramid_archive_graph(fixture: PyramidKernelGraph, cache: Path) [fs, process, env, time, error] -> Result[kbuild.BuiltinArchivePlan] {
  let discovered = fixture.discovered
  let groups = fixture.directories
  let objects = fixture.objects
  let objects_per_group = fixture.objects_per_directory
  let planned = pyramid_plan_archives(discovered, cache)?
  let archive_names = [p".xsh-kbuild/built-in.a", @[fp".xsh-kbuild/{directory}/built-in.a" for directory in groups]]
  let object_names = [fp".xsh-kbuild/obj/{object}" for object in objects]
  assert planned.archives == archive_names
  assert planned.task_count == objects.len() + groups.len() + 1
  assert planned.tasks.len() == planned.task_count
  assert planned.missing_sources == []
  assert planned.generated_objects == []
  assert planned.duplicate_outputs == []
  assert ([task.name for task in planned.tasks] |> sort) == ([item.display() for item in [@object_names, @archive_names]] |> sort)
  for task in planned.tasks {
    assert task.outputs == [fp"{task.name}"]
    if task.name.ends_with(".o") {
      assert task.deps == []
      assert task.inputs == [fp"{task.name.replace(".xsh-kbuild/obj/", with: "").replace(".o", with: ".c")}"]
    } else if task.name == ".xsh-kbuild/built-in.a" {
      assert task.deps == [f".xsh-kbuild/{directory}/built-in.a" for directory in groups]
      assert task.inputs == [fp".xsh-kbuild/{directory}/built-in.a" for directory in groups]
    } else {
      let directory = fp"{task.name}".parent.name
      assert task.deps == [f".xsh-kbuild/obj/{directory}/unit{index}.o" for index in range(objects_per_group)]
      assert task.inputs == [fp".xsh-kbuild/obj/{directory}/unit{index}.o" for index in range(objects_per_group)]
    }
  }
  planned
}

proc pyramid_graph_runner(source: Path) [fs, error] -> Result[Path] {
  let script = fp"{source}/synthetic-task.xsh"
  script.write(r"""let counter = fp"{args[0]}"
let output = fp"{args[1]}"
var text = ""
var latest = 0
for index, value in args {
  continue when index < 2
  let input = fp"{value}"
  text += input.read_text()?
  let modified = fs.stat(input)?.mtime_ns
  if modified > latest { latest = modified }
}
counter.parent.mkdir()?
let previous = if counter.exists()? { counter.read_text()? } else { "" }
counter.write(previous + "x")?
output.parent.mkdir()?
output.write(text)?
fs.set_times(output, mtime_ns: latest + 1000000000)?
""")
  script
}

proc pyramid_graph_counts(source: Path, tasks: List[make.MakeTask]) [fs, error] -> Result[Map[Int]] {
  var counts: Map[Int] = {}
  for task in tasks {
    let counter = fp"{source}/executions/{task.name}"
    counts[task.name] = if counter.exists()? { counter.read_text()?.byte_len() } else { 0 }
  }
  counts
}

proc pyramid_graph_behavior(ctx: TestContext, groups: Int, objects: Int) [fs, process, env, time, error] {
  let fixture = pyramid_kernel_graph(ctx, groups, objects)?
  let source = fixture.source
  let script = pyramid_graph_runner(source)?
  let configured = e"XSH_HOST" ?? ""
  let runner = if configured == "" { process.which("xsh")? } else { fp"{configured}" }
  let cache = test.temp_dir(ctx, name: "pyramid-graph-cache")?
  cd (source) {
    let planned = pyramid_archive_graph(fixture, cache)?
    let tasks: List[make.MakeTask] = [
      {
        ...task,
        argv: [runner, script, "--", fp"{source}/executions/{task.name}", @task.outputs, @task.inputs],
        depfile: p"",
      }
      for task in planned.tasks
    ]
    let selected_output = p".xsh-kbuild/directory0/built-in.a"
    let selected = kbuild.select_archive_tasks_outputs(tasks, [selected_output])?
    assert ([task.name for task in selected] |> sort) == ([".xsh-kbuild/directory0/built-in.a", @[f".xsh-kbuild/obj/directory0/unit{index}.o" for index in range(objects)]] |> sort)
    match kbuild.select_archive_tasks_outputs(tasks, [p"missing-output"]) {
      Ok(_) => test.fail("unknown kernel output selected an executable closure")
      Err(problem) => assert "no archive-plan task produces" in problem.message
    }
    kbuild.run_archive_tasks_output(tasks, selected_output, 2)
    let selected_counts = pyramid_graph_counts(source, tasks)?
    for task in tasks {
      assert selected_counts.get(task.name)? == (if task.name in [item.name for item in selected] { 1 } else { 0 })
    }
    assert p".xsh-kbuild/built-in.a".exists()? == false
    assert selected_output.read_text()? == [fp"directory0/unit{index}.c".read_text()? for index in range(objects)].join("")
    make.run_tasks(tasks, 2)
    let fresh = pyramid_graph_counts(source, tasks)?
    assert fresh.values() == [1 for _ in tasks]
    let expected = [fp"directory{directory}/unit{index}.c".read_text()? for directory in range(groups) for index in range(objects)].join("")
    assert p".xsh-kbuild/built-in.a".read_text()? == expected
    make.run_tasks(tasks, 2)
    assert pyramid_graph_counts(source, tasks)? == fresh
    p"directory0/unit0.c".write("int directory0_unit0(void) { return 1; }\n")
    fs.set_times(p"directory0/unit0.c", mtime_sec: 10)
    make.run_tasks(tasks, 2)
    let changed = pyramid_graph_counts(source, tasks)?
    for task in tasks {
      assert changed.get(task.name)? == (if task.name in [".xsh-kbuild/obj/directory0/unit0.o", ".xsh-kbuild/directory0/built-in.a", ".xsh-kbuild/built-in.a"] { 2 } else { 1 })
    }
    let changed_expected = [fp"directory{directory}/unit{index}.c".read_text()? for directory in range(groups) for index in range(objects)].join("")
    assert p".xsh-kbuild/built-in.a".read_text()? == changed_expected
    make.run_tasks(tasks, 2)
    assert pyramid_graph_counts(source, tasks)? == changed
  }
}

test test_pyramid_kernel_graph_small [fs, process, env, time, error] { |ctx|
  pyramid_graph_behavior(ctx, 2, 2)
}

test test_pyramid_kernel_graph_medium [fs, process, env, time, error] { |ctx|
  pyramid_graph_behavior(ctx, 8, 4)
}


proc pyramid_discovery_source(ctx: TestContext) [fs, error] -> Result[Path] {
  let source = test.temp_dir(ctx, name: "pyramid-prepared-discovery")?
  fp"{source}/Kbuild".write("obj-y += main.o\n")
  fp"{source}/main.c".write("int main(void) { return 0; }\n")
  source
}

test test_pyramid_prepared_discovery_verifies_config_and_exact_inventory [fs, env, error] { |ctx|
  let pkg = recipe.load_package_for_target(p"packages/linux", types.X86_64LinuxMusl)?
  let source = pyramid_discovery_source(ctx)?
  env ({XSH_LINUX_KBUILD_STOP_AFTER: "plan"}) {
    let plan = kbuild_verify.linux_kbuild_discover_prepared(source, pkg, types.X86_64LinuxMusl)?
    assert plan.dirs == [p"."]
    assert plan.objects == [p"main.o"]
    assert plan.lib_objects == []
    assert plan.composites == []
    assert plan.unsupported == []
    assert fp"{source}/.config".read_text()? == p"packages/linux/files/config/x86_64/base-x86_64.fragment".read_text()?
    assert kbuild.read_discovered_plan(fp"{source}/.xsh-kbuild-plan.json")? == plan
    assert fp"{source}/main.o".exists()? == false
    assert fp"{source}/.xsh-kbuild/obj/main.o".exists()? == false
    assert e"XSH_LINUX_KBUILD_STOP_AFTER"? == "plan"
  }
}

test test_pyramid_prepared_discovery_rejects_checksum_before_writes [fs, env, error] { |ctx|
  let original = recipe.load_package_for_target(p"packages/linux", types.X86_64LinuxMusl)?
  let pkg = {
    ...original,
    upstream_sources: [
      {...input, checksums: [{arch: "all", sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]}
      for input in original.upstream_sources
    ],
  }
  let source = pyramid_discovery_source(ctx)?
  test.error_kind(kbuild_verify.linux_kbuild_discover_prepared(source, pkg, types.X86_64LinuxMusl), "checksum-mismatch")?
  assert fp"{source}/.config".exists()? == false
  assert fp"{source}/include".exists()? == false
  assert fp"{source}/.xsh-kbuild-plan.json".exists()? == false
}

test test_pyramid_prepared_discovery_rejects_output_symlink_before_writes [fs, env, error] { |ctx|
  let pkg = recipe.load_package_for_target(p"packages/linux", types.X86_64LinuxMusl)?
  for relative in [
    p".config", p".xsh-kbuild-plan.json", p"include", p"include/generated",
    p"include/generated/autoconf.h", p"include/config", p"include/config/auto.conf",
  ] {
    let source = pyramid_discovery_source(ctx)?
    let sentinel = test.temp_path(ctx, name: "pyramid-discovery-sentinel")
    sentinel.write("unchanged")
    let output = fp"{source}/{relative}"
    output.parent.mkdir()
    output.symlink(to: sentinel)
    match kbuild_verify.linux_kbuild_discover_prepared(source, pkg, types.X86_64LinuxMusl) {
      Ok(_) => test.fail("discovery followed an output symlink")
      Err(kbuild.ScriptError.Failed {kind, message}) => {
        assert kind == "linux-kbuild-case-input"
        assert "discovery output is a symlink" in message
      }
      else => test.fail("discovery did not preserve its input error family")
    }
    assert sentinel.read_text()? == "unchanged"
    if relative != p".config" { assert fp"{source}/.config".exists()? == false }
    if relative != p".xsh-kbuild-plan.json" { assert fp"{source}/.xsh-kbuild-plan.json".exists()? == false }
    assert fp"{source}/main.c".read_text()? == "int main(void) { return 0; }\n"
  }
}

test test_pyramid_prepared_discovery_rejects_unowned_source_and_missing_config [fs, env, error] { |ctx|
  let pkg = recipe.load_package_for_target(p"packages/linux", types.X86_64LinuxMusl)?
  match kbuild_verify.linux_kbuild_discover_prepared(fs.cwd()?, pkg, types.X86_64LinuxMusl) {
    Ok(_) => test.fail("discovery accepted a source outside owned scratch")
    Err(kbuild.ScriptError.Failed {kind, message}) => {
      assert kind == "linux-kbuild-case-input"
      assert "owned directory under .work/tmp" in message
    }
    else => test.fail("discovery did not preserve its input error family")
  }
  let source = pyramid_discovery_source(ctx)?
  match kbuild_verify.linux_kbuild_discover_prepared(source, {...pkg, upstream_sources: []}, types.X86_64LinuxMusl) {
    Ok(_) => test.fail("discovery accepted an undeclared configuration")
    Err(kbuild.ScriptError.Failed {kind, message}) => {
      assert kind == "linux-kbuild-case-input"
      assert "expected one declared" in message
    }
    else => test.fail("discovery did not preserve its input error family")
  }
  assert fp"{source}/.config".exists()? == false
  assert fp"{source}/include".exists()? == false
  assert fp"{source}/.xsh-kbuild-plan.json".exists()? == false
}
