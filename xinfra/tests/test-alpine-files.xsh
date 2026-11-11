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

test files_directories_and_links_converge_drift_and_stay_idempotent_on_alpine { |ctx|
  guard let host = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let resources = [
    declare.directory(id: "base", at: base, mode: 0o750, owner: "root", group_name: "wheel", parents: true)?,
    declare.file(id: "motd", at: f"{base}/motd", text: "hello\n", mode: 0o640, owner: "root", group_name: "wheel", needs: ["base"])?,
    declare.symlink(id: "link", at: f"{base}/current", target: "motd", needs: ["motd"])?,
    declare.command(id: "stamp", argv: ["touch", f"{base}/stamp"], creates: f"{base}/stamp", needs: ["base"])?,
  ]
  let prepared = prepare(host, resources)?
  let first = engine.apply(prepared, settings(dir))
  for id in ["base", "motd", "link", "stamp"] {
    assert testing.status_of(first, host.name, id) == "changed", id
  }
  assert report.exit_status(first) == 0
  let listing = testing.remote_text(host, "stat -c '%a %U %G' -- \"$1\"/motd; cat \"$1\"/motd; readlink \"$1\"/current", [base], privileged: true)?
  assert listing == "640 root wheel\nhello\nmotd\n"

  let second = engine.apply(prepared, settings(dir))
  for id in ["base", "motd", "link"] {
    assert testing.status_of(second, host.name, id) == "unchanged", id
  }
  assert testing.status_of(second, host.name, "stamp") == "skipped"
  let mtime_before = testing.remote_text(host, "stat -c %Y -- \"$1\"/motd", [base], privileged: true)?
  let third = engine.apply(prepared, settings(dir))
  assert testing.remote_text(host, "stat -c %Y -- \"$1\"/motd", [base], privileged: true)? == mtime_before
  assert testing.status_of(third, host.name, "motd") == "unchanged"

  let _ = testing.remote_text(host, "echo tampered > \"$1\"/motd; chmod 666 \"$1\"/motd; chmod 777 \"$1\"", [base], privileged: true)?
  let planned = engine.survey(.Plan, prepared, settings(dir))
  assert testing.status_of(planned, host.name, "motd") == "drift"
  assert testing.status_of(planned, host.name, "base") == "drift"
  let still = testing.remote_text(host, "cat \"$1\"/motd", [base], privileged: true)?
  assert still == "tampered\n"
  let repaired = engine.apply(prepared, settings(dir))
  assert testing.status_of(repaired, host.name, "motd") == "changed"
  assert testing.remote_text(host, "cat \"$1\"/motd; stat -c %a -- \"$1\"", [base], privileged: true)? == "hello\n750\n"
  assert report.exit_status(engine.survey(.Check, prepared, settings(dir))) == 0
}

test hostile_names_survive_the_alpine_login_shell { |ctx|
  guard let host = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let odd = f"{base}/it's a \"dir\"\nwith $(newline) -x"
  let resources = [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.directory(id: "odd", at: odd, needs: ["base"])?,
    declare.file(id: "file", at: f"{odd}/-leading hyphen \\ file", text: "ok\n", needs: ["odd"])?,
    declare.symlink(id: "link", at: f"{odd}/link; rm -rf ~", target: "-leading hyphen \\ file", needs: ["file"])?,
  ]
  let prepared = prepare(host, resources)?
  let first = engine.apply(prepared, settings(dir))
  for id in ["odd", "file", "link"] {
    assert testing.status_of(first, host.name, id) == "changed", id
  }
  let second = engine.apply(prepared, settings(dir))
  for id in ["odd", "file", "link"] {
    assert testing.status_of(second, host.name, id) == "unchanged", id
  }
}

test a_failing_validator_keeps_the_live_file_and_leaves_no_staging_file_on_alpine { |ctx|
  guard let host = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let good = [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.file(id: "conf", at: f"{base}/app.conf", text: "good\n", needs: ["base"])?,
  ]
  let first = engine.apply(prepare(host, good)?, settings(dir))
  assert testing.status_of(first, host.name, "conf") == "changed"

  let bad = [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.file(id: "conf", at: f"{base}/app.conf", text: "bad\n", validate: ["grep", "-q", "good", "{}"], needs: ["base"])?,
  ]
  let second = engine.apply(prepare(host, bad)?, settings(dir))
  assert testing.status_of(second, host.name, "conf") == "failed"
  assert testing.remote_text(host, "cat \"$1\"/app.conf; ls -A \"$1\"", [base], privileged: true)? == "good\napp.conf\n"
}

test a_large_binary_artifact_streams_to_alpine_intact_and_a_second_apply_is_a_no_op { |ctx|
  guard let host = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let blob = fp"{dir}/artifact.bin"
  run dd if=/dev/urandom of=$blob bs=1M count=40 status=none
  let resources = [
    declare.directory(id: "base", at: base, parents: true)?,
    declare.file(id: "blob", at: f"{base}/artifact.bin", source: blob, mode: 0o600, needs: ["base"])?,
  ]
  let prepared = prepare(host, resources)?
  let first = engine.apply(prepared, settings(dir))
  assert testing.status_of(first, host.name, "blob") == "changed"
  let remote = testing.remote_text(host, "sha256sum < \"$1\"/artifact.bin", [base], privileged: true)?
  assert remote.fields()[0] == hash.sha256(blob)?.hex()
  let second = engine.apply(prepared, settings(dir))
  assert testing.status_of(second, host.name, "blob") == "unchanged"
}

test privilege_failure_is_a_failed_host_before_any_mutation { |ctx|
  guard let host = fixture("fx-1-plain")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let resources = [declare.directory(id: "base", at: base, parents: true)?]
  let result = engine.apply(prepare(host, resources)?, settings(dir))
  guard let first = result.hosts |> first() else {
    assert false, "no host report"
    return
  }

  assert ! first.ok
  assert first.phase == "lock"
  assert report.exit_status(result) == 3
  guard let ok_host = fixture("fx-1")? else {
    return
  }

  assert testing.remote_text(ok_host, "test -e \"$1\" && echo present || echo absent", [base])? == "absent\n"
}

test a_wrong_host_key_fails_that_host_and_leaves_the_others_running { |ctx|
  guard let good = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  guard let other = fixture("fx-2")? else {
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/var/tmp/{testing.scratch_name(dir)}"
  let tampered: model.Host = {...other, host_key: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
  let resources = [declare.directory(id: "base", at: base, parents: true)?]
  let hosts = [
    workload.Workload(host: good, resources:),
    workload.Workload(host: tampered, resources:),
  ]
  let prepared = workload.prepare(hosts)?
  let result = engine.apply(prepared, settings(dir))
  assert testing.status_of(result, good.name, "base") == "changed"
  let failed = result.hosts |> where { |item| item.host == other.name } |> collect()
  assert ! failed[0].ok
  assert failed[0].phase == "connect"
  assert testing.remote_text(other, "test -e \"$1\" && echo present || echo absent", [base])? == "absent\n"
}

test unreadable_facts_are_uncertain_and_escalated_reads_make_them_readable { |ctx|
  guard let host = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let base = f"/root/{testing.scratch_name(dir)}"
  let resources = [declare.directory(id: "sealed", at: base)?]
  let unprivileged: model.Host = {...host, escalate_reads: false}
  let planned = engine.survey(.Plan, prepare(unprivileged, resources)?, settings(dir))
  assert testing.status_of(planned, host.name, "sealed") == "uncertain"
  let escalated: model.Host = {...host, escalate_reads: true}
  let again = engine.survey(.Plan, prepare(escalated, resources)?, settings(dir))
  assert testing.status_of(again, host.name, "sealed") == "drift"
}
