use infra.declare
use infra.engine
use infra.model
use infra.report
use infra.testing
use infra.workload

proc settings(dir: Path, policy: engine.FailurePolicy = .Host) -> engine.Settings {
  engine.Settings(jobs: 4, policy:, lock_path: f"/var/tmp/{testing.scratch_name(dir)}.lock")
}

proc prepare(host: model.Host, resources: List[model.Resource]) [fs, env, error] -> Result[workload.Prepared, Error] {
  workload.prepare([workload.Workload(host:, resources:)])
}

proc fixture(name: Str) [env, fs, error] -> Result[model.Host?, Error] {
  testing.fixture_host(name)
}

proc exists(host: model.Host, target: Str) [env, process, error] -> Result[Bool, Error] {
  Ok(testing.remote_text(host, "test -e \"$1\" && echo present || echo absent", [target])? == "present\n")
}

test each_command_condition_runs_once_and_is_skipped_afterwards_on_alpine { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let resources = [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.command(id: "creates", argv: ["sh", "-c", "echo x >> \"$0/creates.log\"; touch \"$0/created\"", base], creates: f"{base}/created", needs: ["base"])?,
    declare.command(id: "skip", shell: f"echo x >> {base}/skip.log; touch {base}/skipped", skip_if_shell: f"test -e {base}/skipped", needs: ["base"])?,
    declare.command(id: "only", shell: f"echo x >> {base}/only.log; rm -f {base}/gate", only_if_shell: f"test -e {base}/gate", needs: ["base"])?,
    declare.command(id: "trigger", argv: ["sh", "-c", "echo x >> \"$0/trigger.log\"", base], run_on: ["marker"], needs: ["marker"])?,
    declare.file(id: "marker", at: f"{base}/marker", text: "1\n", needs: ["base"])?,
    declare.command(id: "always", argv: ["sh", "-c", "echo x >> \"$0/always.log\"", base], always: true, needs: ["base"])?,
  ]
  let _ = testing.remote_text(host, "mkdir -p \"$1\" && touch \"$1/gate\"", [base])?
  let prepared = prepare(host, resources)?

  let planned = engine.survey(.Plan, prepared, settings(dir))
  assert testing.status_of(planned, host.name, "creates") == "drift"
  assert testing.status_of(planned, host.name, "skip") == "drift"
  assert testing.status_of(planned, host.name, "only") == "drift"
  assert ! exists(host, f"{base}/created")?
  assert ! exists(host, f"{base}/skipped")?
  assert exists(host, f"{base}/gate")?

  let first = engine.apply(prepared, settings(dir))
  for id in ["creates", "skip", "only", "trigger", "always"] {
    assert testing.status_of(first, host.name, id) == "changed", report.text(first, true)
  }

  let second = engine.apply(prepared, settings(dir))
  for id in ["creates", "skip", "only", "trigger"] {
    assert testing.status_of(second, host.name, id) == "skipped", id
  }
  assert testing.status_of(second, host.name, "always") == "changed"
  let counts = testing.remote_text(host, "cd \"$1\"; for f in creates skip only trigger always; do wc -l < $f.log; done", [base])?
  assert counts.lines() == ["1", "1", "1", "1", "2"]
}

test a_failing_command_is_failed_with_its_status_and_blocks_what_depends_on_it_on_alpine { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let resources = [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.command(id: "boom", argv: ["sh", "-c", "echo oops >&2; exit 7"], always: true, needs: ["base"])?,
    declare.file(id: "child", at: f"{base}/child", text: "x", needs: ["boom"])?,
    declare.file(id: "later", at: f"{base}/later", text: "x", needs: ["base"])?,
  ]
  let result = engine.apply(prepare(host, resources)?, settings(dir))
  assert testing.status_of(result, host.name, "base") == "changed"
  assert testing.status_of(result, host.name, "boom") == "failed"
  assert testing.status_of(result, host.name, "child") == "blocked"
  assert testing.status_of(result, host.name, "later") == "blocked"
  assert "7" in report.text(result, true)
  assert report.exit_status(result) == 3
  assert ! exists(host, f"{base}/child")?
  assert ! exists(host, f"{base}/later")?

  let continued = engine.apply(prepare(host, resources)?, settings(dir, policy: .Continue))
  assert testing.status_of(continued, host.name, "boom") == "failed"
  assert testing.status_of(continued, host.name, "child") == "blocked"
  assert testing.status_of(continued, host.name, "later") == "changed"

  let accepted = [declare.command(id: "boom", argv: ["sh", "-c", "exit 7"], always: true, accept: [0, 7])?]
  assert testing.status_of(engine.apply(prepare(host, accepted)?, settings(dir)), host.name, "boom") == "changed"
}

test hostile_command_arguments_reach_the_alpine_command_unchanged { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let hostile = "-n 'q\" $(id) `id`; \nline two\\ *"
  let resources = [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.command(id: "echo", argv: ["sh", "-c", "printf '%s' \"$1\" > \"$0/arg\"", base, hostile], always: true, needs: ["base"])?,
  ]
  let result = engine.apply(prepare(host, resources)?, settings(dir))
  assert testing.status_of(result, host.name, "echo") == "changed", report.text(result, true)
  assert testing.remote_text(host, "cat \"$1/arg\"", [base])? == hostile
}

test an_unusable_guard_is_uncertain_and_never_a_reason_to_run_the_command_on_alpine { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let resources = [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.command(id: "guarded", argv: ["touch", f"{base}/ran"], skip_if: ["/no/such/guard"], needs: ["base"])?,
  ]
  let planned = engine.survey(.Plan, prepare(host, resources)?, settings(dir))
  assert testing.status_of(planned, host.name, "guarded") == "uncertain"
  let applied = engine.apply(prepare(host, resources)?, settings(dir))
  assert testing.status_of(applied, host.name, "guarded") != "changed"
  assert ! exists(host, f"{base}/ran")?
}
