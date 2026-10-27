##! Typed task scheduling, argv, stamp reuse, and failed-peer cleanup.
use pm.make

type TaskOutput = {arguments: List[Str], environment: Str}

proc task_runner() -> Result[Path] {
  let configured = e"XSH_HOST" ?? ""
  return fp"{configured}" when configured != ""
  process.which("xsh")?
}

pure task(
  name: Str,
  root: Path,
  command: List[Any],
  outputs: List[Path],
  inputs: List[Path] = [],
  deps: List[Str] = [],
) -> make.MakeTask {
  {
    name,
    outputs,
    inputs,
    deps,
    argv: command,
    cwd: root,
    env: {TASK_LABEL: "literal environment value"},
    depfile: p"",
    stamp: fp"{root}/{name}.cmd",
  }
}

test make_plan_preserves_graph_inventory_without_effects [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "make plan")?
  let output = fp"{root}/output"
  let base = task("base", root, ["touch", output], [output])
  let left = task("left", root, ["touch", output], [fp"{root}/left"], deps: ["base"])
  let right = task("right", root, ["touch", output], [fp"{root}/right"], deps: ["base"])
  let top = task("top", root, ["touch", output], [fp"{root}/top"], deps: ["right", "left"])
  let detached = task("detached", root, ["touch", output], [])
  let inventory = make.plan_tasks([top, detached, right, base, left])?
  assert [item.name for item in inventory] == ["top", "detached", "right", "base", "left"]
  assert inventory[0].deps == ["right", "left"]
  assert inventory[2].deps == ["base"]
  assert inventory[3].outputs == [output]
  assert make.plan_tasks([])?.is_empty()
  assert ! output.exists()?
  assert ! top.stamp.exists()?
}

test make_plan_rejects_invalid_graphs [error] {
  let a = task("a", p".", ["true"], [p"a"])
  let b = task("b", p".", ["true"], [p"b"], deps: ["a"])
  match make.plan_tasks([a, a]) {
    Ok(_) => test.fail("duplicate names accepted")
    Err(problem) => assert problem.message.starts_with("duplicate make")
  }
  match make.plan_tasks([a, {...b, outputs: [p"a"]}]) {
    Ok(_) => test.fail("duplicate outputs accepted")
    Err(problem) => assert problem.message.starts_with("duplicate make")
  }
  match make.plan_tasks([b]) {
    Ok(_) => test.fail("missing dependency accepted")
    Err(problem) => assert problem.message.starts_with("make task")
  }
  match make.plan_tasks([{...a, name: ""}]) {
    Ok(_) => test.fail("empty name accepted")
    Err(problem) => assert problem is InvalidData
  }
  match make.plan_tasks([{...a, argv: []}]) {
    Ok(_) => test.fail("empty argv accepted")
    Err(problem) => assert problem is InvalidData
  }
  match make.plan_tasks([{...a, outputs: [p""]}]) {
    Ok(_) => test.fail("empty output accepted")
    Err(problem) => assert problem is InvalidData
  }
  match make.plan_tasks([{...a, deps: ["a"]}]) {
    Ok(_) => test.fail("self cycle accepted")
    Err(problem) => assert problem.message == "cycle in make task graph"
  }
  match make.plan_tasks([{...a, deps: ["b"]}, b]) {
    Ok(_) => test.fail("cycle accepted")
    Err(problem) => assert problem.message == "cycle in make task graph"
  }
}

test make_scheduler_contract_invalid_jobs_precede_invalid_graph [fs, process, env, error] {
  let invalid = task("", p".", [], [])
  match make.run_tasks([invalid], 0) {
    Ok(_) => test.fail("invalid jobs accepted")
    Err(problem) => assert problem.message == "job count must be positive"
  }
}

test make_scheduler_contract_ready_task_runs_before_disconnected_cycle [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "make cycle timing")?
  let script = fp"{root}/write.xsh"
  let output = fp"{root}/output"
  script.write(r"""fp"{args[0]}".write("completed")?
""")?
  let ready = task("ready", root, [task_runner()?, script, "--", output], [output])
  let a = task("a", root, ["unused"], [], deps: ["b"])
  let b = task("b", root, ["unused"], [], deps: ["a"])
  match make.run_tasks([a, ready, b], 1) {
    Ok(_) => test.fail("cycle accepted")
    Err(problem) => assert problem.message == "cycle in make task graph"
  }
  assert output.read_text()? == "completed"
  assert ! ready.stamp.exists()?
}

test make_tasks_preserve_typed_argv_dependencies_and_stamp_reuse [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "make task argv")?
  let script = fp"{root}/task runner.xsh"
  script.write(r"""let output = fp"{args[0]}"
let counter = fp"{args[2]}"
if args.len() > 3 { let _ = fp"{args[3]}".read_text()? }
counter.write((counter.read_text() ?? "") + "x")?
json.write(output, {arguments: args, environment: env.get("TASK_LABEL") ?? ""})?
""")
  let runner = task_runner()?
  let first_output = fp"{root}/first output.json"
  let second_output = fp"{root}/second output.json"
  let first_counter = fp"{root}/first count"
  let second_counter = fp"{root}/second count"
  let payload = "spaces 'quotes' $literal"
  let first = task(
    "first",
    root,
    [runner, script, "--", first_output, payload, first_counter],
    [first_output],
    [script],
  )
  let second = task(
    "second",
    root,
    [runner, script, "--", second_output, payload, second_counter, first_output],
    [second_output],
    [script, first_output],
    ["first"],
  )
  make.run_tasks([second, first], 2)
  let observed = json.read(second_output)?.require(TaskOutput)?
  assert observed.arguments == [second_output.display(), payload, second_counter.display(), first_output.display()]
  assert observed.environment == "literal environment value"
  assert first_counter.read_text()? == "x"
  assert second_counter.read_text()? == "x"
  make.run_tasks([second, first], 2)
  assert first_counter.read_text()? == "x"
  assert second_counter.read_text()? == "x"
}

test make_tasks_rebuild_for_subsecond_input_changes [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "make subsecond input")?
  let input = fp"{root}/input"
  let output = fp"{root}/output"
  input.write("old")
  let copy = task("copy", root, ["/bin/cp", input, output], [output], [input])
  make.run_tasks([copy], 1)
  input.write("new")
  fs.set_times(output, mtime_sec: 1700000000, mtime_nsec: 100)?
  fs.set_times(input, mtime_sec: 1700000000, mtime_nsec: 200)?
  make.run_tasks([copy], 1)
  assert output.read_text()? == "new"
}

test make_tasks_cancel_running_peers_and_do_not_publish_failed_stamps [fs, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "failed make tasks")?
  let peer_script = fp"{root}/peer.xsh"
  let failure_script = fp"{root}/failure.xsh"
  let started = fp"{root}/started"
  let late_output = fp"{root}/late output"
  peer_script.write(r"""fp"{args[0]}".write("started")?
run sh -c "sleep 1" ?
fp"{args[1]}".write("should have been cancelled")?
""")
  failure_script.write(r"""while ! fp"{args[0]}".exists()? { time.sleep(10ms)? }
error.fail("task fixture failed")?
""")
  let runner = task_runner()?
  let peer = task("peer", root, [runner, peer_script, "--", started, late_output], [late_output])
  let failure = task("failure", root, [runner, failure_script, "--", started], [fp"{root}/failure output"])
  match make.run_tasks([peer, failure], 2) {
    Ok(_) => test.fail("failed command unexpectedly completed its task graph")
    Err(problem) => {
      assert problem is ProcessFailure
      assert problem.message == "make task 'failure' failed"
    }
  }

  assert started.exists()?
  time.sleep(1100ms)
  assert ! late_output.exists()?
  assert ! peer.stamp.exists()?
  assert ! failure.stamp.exists()?
}

test make_task_argv_accepts_only_text_and_path_words [error] {
  assert make.argv_text(["cc", p"src/main.c", "-o", p"out dir/main"])? == ["cc", "src/main.c", "-o", "out dir/main"]
  match make.argv_text(["cc", 2]) {
    Ok(_) => test.fail("an Int argv word unexpectedly became process text")
    Err(problem) => assert problem is InvalidData
  }
}

test make_pkg_config_flags_preserve_checked_compiler_and_linker_lists [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "pkg config flags")?
  let runner = task_runner()?
  let tool = fp"{root}/pkg-config"
  tool.write(
    f"""#!{runner}
if args == ["--cflags", "libone", "libtwo"] {{
  print "-I/usr/include/example -DEXAMPLE=1"
}} else if args == ["--libs", "libone", "libtwo"] {{
  print "-L/usr/lib/example -lexample"
}} else {{
  error.fail("unexpected pkg-config arguments")?
}}
""",
    mode: 0o755,
  )
  env ({PATH: f"{root}:{e"PATH" ?? ""}", XSH_PM_TARGET_ROOT: ""}) {
    let flags = make.pkg_config_flags(["libone", "libtwo"])?
    assert flags.cflags == ["-I/usr/include/example", "-DEXAMPLE=1"]
    assert flags.libs == ["-L/usr/lib/example", "-lexample"]
  }?
}
