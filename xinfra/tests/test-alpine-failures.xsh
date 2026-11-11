use infra.declare
use infra.engine
use infra.model
use infra.report
use infra.testing
use infra.workload

proc settings(dir: Path, policy: engine.FailurePolicy = .Host) -> engine.Settings {
  engine.Settings(jobs: 4, policy:, lock_path: f"/var/tmp/{testing.scratch_name(dir)}.lock")
}

proc fixture(name: Str) [env, fs, error] -> Result[model.Host?, Error] {
  testing.fixture_host(name)
}

proc exists(host: model.Host, target: Str) [env, process, error] -> Result[Bool, Error] {
  Ok(testing.remote_text(host, "test -e \"$1\" && echo present || echo absent", [target])? == "present\n")
}

proc host_report(result: report.Report, name: Str) -> report.HostReport {
  (result.hosts |> where { |item| item.host == name } |> collect())[0]
}

test an_unreachable_host_is_a_connect_failure_in_every_mode_and_never_a_success { |ctx|
  guard let host = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let nowhere: model.Host = {...host, name: "nowhere", address: "127.0.0.1", port: 1, timeout_ms: 2000}
  let resources = [declare.directory(id: "base", at: base, parents: true)?]
  let prepared = workload.prepare([workload.Workload(host: nowhere, resources:)])?
  for result in [engine.survey(.Plan, prepared, settings(dir)), engine.survey(.Check, prepared, settings(dir)), engine.apply(prepared, settings(dir))] {
    let failed = host_report(result, "nowhere")
    assert ! failed.ok
    assert failed.phase == "connect"
    assert failed.entries.is_empty()
    assert report.exit_status(result) == 3
  }
}

test an_authentication_failure_is_a_connect_failure_before_any_mutation { |ctx|
  guard let host = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let stranger = fp"{dir}/stranger"
  run ssh-keygen -q -t ed25519 -N "" -f $stranger
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let denied: model.Host = {...host, name: "denied", key: stranger}
  let resources = [declare.directory(id: "base", at: base, parents: true)?]
  let prepared = workload.prepare([workload.Workload(host: denied, resources:)])?
  let result = engine.apply(prepared, settings(dir))
  let failed = host_report(result, "denied")
  assert ! failed.ok
  assert failed.phase == "connect"
  assert report.exit_status(result) == 3
  assert ! exists(host, base)?
}

test a_host_that_fails_midway_keeps_its_earlier_changes_and_never_hides_the_healthy_host { |ctx|
  guard let healthy = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  guard let failing = fixture("fx-2")? else {
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let resources = [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.file(id: "first", at: f"{base}/first", text: "1\n", needs: ["base"])?,
    declare.command(id: "gate", argv: ["test", "-e", f"{base}.open"], always: true, needs: ["first"])?,
    declare.file(id: "last", at: f"{base}/last", text: "2\n", needs: ["gate"])?,
  ]
  let _ = testing.remote_text(healthy, "touch \"$1.open\"", [base])?
  let prepared = workload.prepare([
    workload.Workload(host: healthy, resources:),
    workload.Workload(host: failing, resources:),
  ])?
  let result = engine.apply(prepared, settings(dir))
  for id in ["base", "first", "gate", "last"] {
    assert testing.status_of(result, healthy.name, id) == "changed", id
  }

  assert testing.status_of(result, failing.name, "first") == "changed"
  assert testing.status_of(result, failing.name, "gate") == "failed"
  assert testing.status_of(result, failing.name, "last") == "blocked"
  assert exists(failing, f"{base}/first")?
  assert ! exists(failing, f"{base}/last")?
  assert exists(healthy, f"{base}/last")?
  assert report.exit_status(result) == 3

  let _ = testing.remote_text(failing, "touch \"$1.open\"", [base])?
  let repaired = engine.apply(prepared, settings(dir))
  assert testing.status_of(repaired, failing.name, "first") == "unchanged"
  assert testing.status_of(repaired, failing.name, "last") == "changed"
  assert report.exit_status(repaired) == 0
}

test an_unavailable_package_is_a_failure_and_changes_nothing_else { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let resources = [
    declare.package(id: "ghost", name: "xinfra-no-such-package")?,
    declare.directory(id: "base", at: base, parents: true)?,
  ]
  let prepared = workload.prepare([workload.Workload(host:, resources:)])?
  let result = engine.apply(prepared, settings(dir))
  assert testing.status_of(result, host.name, "ghost") == "failed"
  assert testing.status_of(result, host.name, "base") == "blocked"
  assert report.exit_status(result) == 3
  assert ! exists(host, base)?
  assert testing.remote_text(host, "apk info -e xinfra-no-such-package || echo absent", [])? == "absent\n"
}
