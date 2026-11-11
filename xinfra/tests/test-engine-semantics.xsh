use infra.declare
use infra.engine
use infra.model
use infra.report
use infra.testing
use infra.workload

proc settings(dir: Path, jobs: Int = 4, policy: engine.FailurePolicy = .Host) -> engine.Settings {
  engine.Settings(jobs:, policy:, lock_path: f"{dir}/.lock-{{host}}")
}

proc prepare(hosts: List[workload.Workload]) [fs, env, error] -> Result[workload.Prepared, Error] {
  workload.prepare(hosts)
}

pure on(name: Str, resources: List[model.Resource]) -> workload.Workload {
  workload.Workload(host: testing.local_host(name), resources:)
}

pure logged(id: Str, log: Path, host: Str) -> Result[model.Resource, Error] {
  declare.command(
    id:,
    argv: ["sh", "-c", "echo start $0 $1 >> \"$2\"; sleep 0.4; echo end $0 $1 >> \"$2\"", id, host, f"{log}"],
    always: true,
  )
}

proc lines_of(log: Path) [fs] -> List[Str] {
  (log.read_text() ?? "").lines()
}

pure first_index(lines: List[Str], needle: Str) -> Int {
  for index in range(lines.len()) {
    if needle in lines[index] {
      return index
    }
  }

  -1
}

pure last_index(lines: List[Str], needle: Str) -> Int {
  var found = -1
  for index in range(lines.len()) {
    if needle in lines[index] {
      found = index
    }
  }

  found
}

test every_host_finishes_an_operation_before_any_host_starts_the_next { |ctx|
  let dir = test.temp_dir(ctx)?
  let log = fp"{dir}/log"
  let hosts = ["h1", "h2", "h3"] |> map { |name| on(name, [logged("one", log, name)?, logged("two", log, name)?]) } |> collect()
  let result = engine.apply(prepare(hosts)?, settings(dir, jobs: 3))
  assert report.exit_status(result) == 0
  let lines = lines_of(log)
  assert lines.len() == 12
  let first_two = first_index(lines, " two ")
  let last_one = last_index(lines, " one ")
  assert first_two >= 0 and last_one >= 0
  assert last_one < first_two, f"operation two started before one finished: {lines.join("|")}"
}

test the_job_bound_limits_how_many_hosts_run_at_once { |ctx|
  let dir = test.temp_dir(ctx)?
  let log = fp"{dir}/log"
  let hosts = ["h1", "h2", "h3"] |> map { |name| on(name, [logged("one", log, name)?]) } |> collect()
  let serial = engine.apply(prepare(hosts)?, settings(dir, jobs: 1))
  assert report.exit_status(serial) == 0
  let kinds = lines_of(log) |> map { |line| line.split(" ")[0] } |> collect()
  assert kinds == ["start", "end", "start", "end", "start", "end"]

  let wide = fp"{dir}/wide"
  let wide_hosts = ["h1", "h2", "h3"] |> map { |name| on(name, [logged("one", wide, name)?]) } |> collect()
  let parallel = engine.apply(prepare(wide_hosts)?, settings(dir, jobs: 3))
  assert report.exit_status(parallel) == 0
  let overlapped = lines_of(wide) |> map { |line| line.split(" ")[0] } |> collect()
  assert overlapped[0..3] == ["start", "start", "start"]
}

test several_changed_files_coalesce_into_one_trigger { |ctx|
  let dir = test.temp_dir(ctx)?
  let counter = fp"{dir}/runs"
  let resources = [
    declare.file(id: "a", at: f"{dir}/a", text: "1\n")?,
    declare.file(id: "b", at: f"{dir}/b", text: "2\n")?,
    declare.command(id: "reload", argv: ["sh", "-c", "echo run >> \"$0\"", f"{counter}"], run_on: ["a", "b"])?,
  ]
  let prepared = prepare([on("h", resources)])?
  let first = engine.apply(prepared, settings(dir))
  assert testing.status_of(first, "h", "reload") == "changed"
  assert lines_of(counter) == ["run"]
  let second = engine.apply(prepared, settings(dir))
  assert testing.status_of(second, "h", "reload") == "skipped"
  assert lines_of(counter) == ["run"]
  fp"{dir}/b".write("changed elsewhere\n")
  let third = engine.apply(prepared, settings(dir))
  assert lines_of(counter) == ["run", "run"]
  assert testing.status_of(third, "h", "b") == "changed"
}

test absent_resources_are_removed_and_never_recursively { |ctx|
  let dir = test.temp_dir(ctx)?
  fp"{dir}/file".write("x")
  fp"{dir}/empty".mkdir()
  fp"{dir}/full".mkdir()
  fp"{dir}/full/keep".write("x")
  fp"{dir}/link".symlink(to: p"file")
  let resources = [
    declare.file(id: "file", at: f"{dir}/file", presence: .Absent)?,
    declare.directory(id: "empty", at: f"{dir}/empty", presence: .Absent)?,
    declare.directory(id: "full", at: f"{dir}/full", presence: .Absent)?,
    declare.symlink(id: "link", at: f"{dir}/link", presence: .Absent)?,
  ]
  let result = engine.apply(prepare([on("h", resources)])?, settings(dir, policy: .Continue))
  assert testing.status_of(result, "h", "file") == "changed"
  assert testing.status_of(result, "h", "empty") == "changed"
  assert testing.status_of(result, "h", "link") == "changed"
  assert testing.status_of(result, "h", "full") == "failed"
  assert fp"{dir}/full/keep".exists()?
  assert ! fp"{dir}/file".exists()?
}

test a_command_that_outlives_its_timeout_has_an_unknown_outcome_and_is_not_retried { |ctx|
  let dir = test.temp_dir(ctx)?
  let counter = fp"{dir}/runs"
  let resources = [
    declare.command(id: "slow", argv: ["sh", "-c", "echo run >> \"$0\"; sleep 5", f"{counter}"], always: true, timeout_seconds: 1)?,
    declare.file(id: "after", at: f"{dir}/after", text: "x", needs: ["slow"])?,
  ]
  let result = engine.apply(prepare([on("h", resources)])?, settings(dir))
  assert testing.status_of(result, "h", "slow") == "unknown"
  assert testing.status_of(result, "h", "after") == "blocked"
  assert lines_of(counter) == ["run"]
  assert report.exit_status(result) == 3
}

test secret_values_never_reach_a_report { |ctx|
  let dir = test.temp_dir(ctx)?
  env ({XINFRA_TEST_SECRET: "hunter2-secret"}) {
    let resources = [
      declare.file(id: "key", at: f"{dir}/key", secret_env: "XINFRA_TEST_SECRET", mode: 0o600)?,
      declare.command(id: "leak", argv: ["sh", "-c", "echo token=$(cat \"$0\") >&2; exit 3", f"{dir}/key"], always: true, needs: ["key"])?,
    ]
    let prepared = prepare([on("h", resources)])?
    let planned = engine.survey(.Plan, prepared, settings(dir))
    let applied = engine.apply(prepared, settings(dir))
    for result in [planned, applied] {
      let text = report.text(result, true)
      let document = report.json_document(result)?
      let lines = report.json_lines(result)?
      for rendered in [text, document, lines] {
        assert "hunter2-secret" not in rendered
      }
    }
    assert testing.status_of(applied, "h", "leak") == "failed"
    assert fp"{dir}/key".read_text()? == "hunter2-secret"
    assert fp"{dir}/key".metadata()?.mode % 4096 == 0o600
  }
}

test unset_secrets_and_missing_sources_are_refused_before_any_mutation { |ctx|
  let dir = test.temp_dir(ctx)?
  let missing_secret = [declare.file(id: "key", at: f"{dir}/key", secret_env: "XINFRA_TEST_UNSET_VARIABLE")?]
  assert prepare([on("h", missing_secret)]) is Err(_)
  let missing_source = [declare.file(id: "src", at: f"{dir}/src", source: fp"{dir}/nope")?]
  assert prepare([on("h", missing_source)]) is Err(_)
  let duplicate = [declare.file(id: "x", at: f"{dir}/x", text: "1")?, declare.file(id: "x", at: f"{dir}/y", text: "1")?]
  assert prepare([on("h", duplicate)]) is Err(_)
  assert ! fp"{dir}/x".exists()?
}

test hostile_paths_converge_like_any_other { |ctx|
  let dir = test.temp_dir(ctx)?
  let odd = f"{dir}/it's a \"dir\"\nwith $(newline) -x"
  let resources = [
    declare.directory(id: "odd", at: odd)?,
    declare.file(id: "file", at: f"{odd}/-leading hyphen \\ file", text: "ok\n", needs: ["odd"])?,
    declare.symlink(id: "link", at: f"{odd}/link; rm -rf ~", target: "-leading hyphen \\ file", needs: ["file"])?,
  ]
  let prepared = prepare([on("h", resources)])?
  let first = engine.apply(prepared, settings(dir))
  for id in ["odd", "file", "link"] {
    assert testing.status_of(first, "h", id) == "changed", id
  }
  let second = engine.apply(prepared, settings(dir))
  for id in ["odd", "file", "link"] {
    assert testing.status_of(second, "h", id) == "unchanged"
  }
  assert fp"{odd}/-leading hyphen \\ file".read_text()? == "ok\n"
}

test apply_recomputes_from_current_facts_not_from_the_plan { |ctx|
  let dir = test.temp_dir(ctx)?
  let resources = [declare.file(id: "f", at: f"{dir}/f", text: "same\n")?]
  let prepared = prepare([on("h", resources)])?
  let planned = engine.survey(.Plan, prepared, settings(dir))
  assert testing.status_of(planned, "h", "f") == "drift"
  fp"{dir}/f".write("same\n")
  fp"{dir}/f".chmod(0o644)
  let applied = engine.apply(prepared, settings(dir))
  assert testing.status_of(applied, "h", "f") == "unchanged"
}

test a_plan_marks_resources_that_depend_on_a_planned_change_as_conditional { |ctx|
  let dir = test.temp_dir(ctx)?
  let resources = [
    declare.directory(id: "d", at: f"{dir}/d")?,
    declare.file(id: "f", at: f"{dir}/d/f", text: "x", needs: ["d"])?,
  ]
  let planned = engine.survey(.Plan, prepare([on("h", resources)])?, settings(dir))
  guard let entry = testing.entry_of(planned, "h", "f") else {
    assert false, "no entry"
    return
  }

  assert entry.conditional
  guard let root = testing.entry_of(planned, "h", "d") else {
    assert false, "no entry"
    return
  }

  assert ! root.conditional
}

test a_binary_source_file_is_replaced_atomically_and_streamed { |ctx|
  let dir = test.temp_dir(ctx)?
  let source = fp"{dir}/source.bin"
  run dd if=/dev/urandom of=$source bs=1M count=20 status=none
  let resources = [declare.file(id: "blob", at: f"{dir}/blob", source: source, mode: 0o600)?]
  let prepared = prepare([on("h", resources)])?
  let first = engine.apply(prepared, settings(dir))
  assert testing.status_of(first, "h", "blob") == "changed"
  assert hash.sha256(fp"{dir}/blob")?.hex() == hash.sha256(source)?.hex()
  let second = engine.apply(prepared, settings(dir))
  assert testing.status_of(second, "h", "blob") == "unchanged"
}

test the_abort_policy_stops_every_host_after_a_failure { |ctx|
  let dir = test.temp_dir(ctx)?
  let failing = [declare.file(id: "one", at: f"{dir}/nope/x", text: "x")?, declare.file(id: "two", at: f"{dir}/two-bad", text: "x")?]
  let fine = [declare.file(id: "one", at: f"{dir}/one-good", text: "x")?, declare.file(id: "two", at: f"{dir}/two-good", text: "x")?]
  let hosts = [on("bad", failing), on("good", fine)]
  let result = engine.apply(prepare(hosts)?, settings(dir, policy: .Abort))
  assert testing.status_of(result, "bad", "one") == "failed"
  assert testing.status_of(result, "good", "one") == "changed"
  assert testing.status_of(result, "good", "two") == "blocked"
  assert ! fp"{dir}/two-good".exists()?
}
