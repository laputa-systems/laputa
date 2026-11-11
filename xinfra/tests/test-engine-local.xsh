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

pure single(name: Str, resources: List[model.Resource]) -> List[workload.Workload] {
  [workload.Workload(host: testing.local_host(name), resources:)]
}

proc site(dir: Path) [error] -> Result[List[model.Resource], Error] {
  [
    declare.directory(id: "root", at: f"{dir}/site", mode: 0o750)?,
    declare.directory(id: "conf", at: f"{dir}/site/conf", mode: 0o700, needs: ["root"])?,
    declare.file(id: "motd", at: f"{dir}/site/motd", text: "hello\n", mode: 0o640, needs: ["root"])?,
    declare.symlink(id: "current", at: f"{dir}/site/current", target: "motd", needs: ["motd"])?,
    declare.command(id: "stamp", argv: ["touch", f"{dir}/site/stamp"], creates: f"{dir}/site/stamp", needs: ["root"])?,
  ]
}

test the_first_apply_converges_and_the_second_changes_nothing { |ctx|
  let dir = test.temp_dir(ctx)?
  let prepared = prepare(single("a", site(dir)?))?
  let first = engine.apply(prepared, settings(dir))
  for id in ["root", "conf", "motd", "current", "stamp"] {
    assert testing.status_of(first, "a", id) == "changed", f"{id}: {testing.status_of(first, "a", id)}"
  }
  assert report.exit_status(first) == 0
  assert fp"{dir}/site/motd".read_text()? == "hello\n"
  assert fp"{dir}/site/current".readlink()? == p"motd"
  let before = fp"{dir}/site/motd".metadata()?.modified

  let second = engine.apply(prepared, settings(dir))
  assert testing.status_of(second, "a", "root") == "unchanged"
  assert testing.status_of(second, "a", "motd") == "unchanged"
  assert testing.status_of(second, "a", "current") == "unchanged"
  assert testing.status_of(second, "a", "stamp") == "skipped"
  assert fp"{dir}/site/motd".metadata()?.modified == before
}

test plan_and_check_change_nothing_and_say_what_would_change { |ctx|
  let dir = test.temp_dir(ctx)?
  let prepared = prepare(single("a", site(dir)?))?
  let planned = engine.survey(.Plan, prepared, settings(dir))
  assert testing.status_of(planned, "a", "root") == "drift"
  assert testing.status_of(planned, "a", "motd") == "drift"
  assert ! fp"{dir}/site".exists()?
  assert report.exit_status(planned) == 0

  let checked = engine.survey(.Check, prepared, settings(dir))
  assert report.exit_status(checked) == 1
  let applied = engine.apply(prepared, settings(dir))
  assert report.exit_status(applied) == 0
  let compliant = engine.survey(.Check, prepared, settings(dir))
  assert report.exit_status(compliant) == 0
  assert testing.status_of(compliant, "a", "stamp") == "satisfied"
}

test deliberate_drift_is_detected_and_repaired { |ctx|
  let dir = test.temp_dir(ctx)?
  let prepared = prepare(single("a", site(dir)?))?
  let _ = engine.apply(prepared, settings(dir))
  fp"{dir}/site/motd".write("tampered\n")
  fp"{dir}/site/motd".chmod(0o666)
  fp"{dir}/site/conf".chmod(0o755)
  let checked = engine.survey(.Check, prepared, settings(dir))
  assert testing.status_of(checked, "a", "motd") == "drift"
  assert testing.status_of(checked, "a", "conf") == "drift"
  let repaired = engine.apply(prepared, settings(dir))
  assert testing.status_of(repaired, "a", "motd") == "changed"
  assert testing.status_of(repaired, "a", "conf") == "changed"
  assert fp"{dir}/site/motd".read_text()? == "hello\n"
  assert fp"{dir}/site/motd".metadata()?.mode % 4096 == 0o640
  assert report.exit_status(engine.survey(.Check, prepared, settings(dir))) == 0
}

test a_failing_validator_leaves_the_live_file_and_removes_the_staging_file { |ctx|
  let dir = test.temp_dir(ctx)?
  let live = fp"{dir}/app.conf"
  live.write("good\n")
  let resource = declare.file(id: "conf", at: f"{live}", text: "bad\n", validate: ["sh", "-c", "grep -q good \"$1\"", "validator", "{}"])?
  let prepared = prepare(single("a", [resource]))?
  let result = engine.apply(prepared, settings(dir))
  assert testing.status_of(result, "a", "conf") == "failed"
  guard let entry = testing.entry_of(result, "a", "conf") else {
    assert false, "no entry"
    return
  }

  assert entry.phase == "validate"
  assert live.read_text()? == "good\n"
  let leftovers = fs.children(dir)? |> where { |child| child.name.starts_with(".xinfra.") } |> count()
  assert leftovers == 0
}

test a_passing_validator_promotes_the_staged_file { |ctx|
  let dir = test.temp_dir(ctx)?
  let live = fp"{dir}/app.conf"
  live.write("good\n")
  let resource = declare.file(id: "conf", at: f"{live}", text: "better good\n", validate: ["sh", "-c", "grep -q good \"$1\"", "validator", "{}"])?
  let result = engine.apply(prepare(single("a", [resource]))?, settings(dir))
  assert testing.status_of(result, "a", "conf") == "changed"
  assert live.read_text()? == "better good\n"
}

test a_failure_blocks_dependents_and_later_resources_on_that_host { |ctx|
  let dir = test.temp_dir(ctx)?
  let resources = [
    declare.file(id: "orphan", at: f"{dir}/missing/dir/file", text: "x")?,
    declare.file(id: "child", at: f"{dir}/child", text: "x", needs: ["orphan"])?,
    declare.file(id: "other", at: f"{dir}/other", text: "x")?,
  ]
  let result = engine.apply(prepare(single("a", resources))?, settings(dir))
  assert testing.status_of(result, "a", "orphan") == "failed"
  assert testing.status_of(result, "a", "child") == "blocked"
  assert testing.status_of(result, "a", "other") == "blocked"
  assert ! fp"{dir}/other".exists()?
  assert report.exit_status(result) == 3

  let independent = engine.apply(prepare(single("a", resources))?, settings(dir, policy: .Continue))
  assert testing.status_of(independent, "a", "orphan") == "failed"
  assert testing.status_of(independent, "a", "child") == "blocked"
  assert testing.status_of(independent, "a", "other") == "changed"
  assert fp"{dir}/other".exists()?
}

test a_type_conflict_is_refused_without_touching_the_path { |ctx|
  let dir = test.temp_dir(ctx)?
  fp"{dir}/thing".write("i am a file\n")
  let resources = [declare.directory(id: "thing", at: f"{dir}/thing")?]
  let planned = engine.survey(.Plan, prepare(single("a", resources))?, settings(dir))
  assert testing.status_of(planned, "a", "thing") == "conflict"
  let result = engine.apply(prepare(single("a", resources))?, settings(dir))
  assert testing.status_of(result, "a", "thing") == "failed"
  assert fp"{dir}/thing".read_text()? == "i am a file\n"
}

test one_failed_host_does_not_stop_the_healthy_ones { |ctx|
  let dir = test.temp_dir(ctx)?
  let good = [declare.file(id: "motd", at: f"{dir}/good", text: "x")?]
  let bad = [declare.file(id: "motd", at: f"{dir}/missing/bad", text: "x")?]
  let hosts = [
    workload.Workload(host: testing.local_host("good-1"), resources: good),
    workload.Workload(host: testing.local_host("bad-1"), resources: bad),
  ]
  let result = engine.apply(prepare(hosts)?, settings(dir))
  assert testing.status_of(result, "good-1", "motd") == "changed"
  assert testing.status_of(result, "bad-1", "motd") == "failed"
  assert fp"{dir}/good".exists()?
  assert report.exit_status(result) == 3
}

test an_unreadable_directory_makes_facts_uncertain_not_absent { |ctx|
  if user.current()?.uid == 0 {
    test.skip("permissions do not bind root")
    return
  }

  let dir = test.temp_dir(ctx)?
  fp"{dir}/sealed".mkdir()
  fp"{dir}/sealed/inner".write("x")
  fp"{dir}/sealed".chmod(0o000)
  defer { fp"{dir}/sealed".chmod(0o700) }
  let resources = [declare.file(id: "inner", at: f"{dir}/sealed/inner", text: "x")?]
  let planned = engine.survey(.Plan, prepare(single("a", resources))?, settings(dir))
  assert testing.status_of(planned, "a", "inner") == "uncertain"
  let applied = engine.apply(prepare(single("a", resources))?, settings(dir))
  assert testing.status_of(applied, "a", "inner") == "failed"
}
