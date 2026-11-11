use infra.declare
use infra.engine
use infra.model
use infra.report
use infra.testing
use infra.workload

proc settings(dir: Path) -> engine.Settings {
  engine.Settings(jobs: 4, policy: .Host, lock_path: f"/var/tmp/{testing.scratch_name(dir)}.lock")
}

proc prepare(host: model.Host, resources: List[model.Resource]) [fs, env, error] -> Result[workload.Prepared, Error] {
  workload.prepare([workload.Workload(host:, resources:)])
}

proc fixture(name: Str) [env, fs, error] -> Result[model.Host?, Error] {
  testing.fixture_host(name)
}

test groups_and_users_converge_never_change_ids_and_never_delete_data { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let suffix = dir.parent().name().replace("_", with: "-")
  let group_name = f"g{suffix.byte_slice(suffix.byte_len() - 8)}"
  let user_name = f"u{suffix.byte_slice(suffix.byte_len() - 8)}"
  let resources = [
    declare.group_account(id: "g", name: group_name, gid: 4321)?,
    declare.user_account(id: "u", name: user_name, uid: 4322, primary_group: group_name, groups: ["wheel"], home: f"/home/{user_name}", shell: "/bin/ash", needs: ["g"])?,
  ]
  let prepared = prepare(host, resources)?
  let first = engine.apply(prepared, settings(dir))
  assert testing.status_of(first, host.name, "g") == "changed"
  assert testing.status_of(first, host.name, "u") == "changed"
  let facts = testing.remote_text(host, "id -u -- \"$1\"; id -Gn -- \"$1\"; getent group \"$2\"", [user_name, group_name])?
  assert facts.lines()[0] == "4322"
  assert "wheel" in facts.lines()[1]
  assert group_name in facts.lines()[2]

  let second = engine.apply(prepared, settings(dir))
  assert testing.status_of(second, host.name, "g") == "unchanged"
  assert testing.status_of(second, host.name, "u") == "unchanged"

  let wrong_uid = [declare.user_account(id: "u", name: user_name, uid: 5555)?]
  let refused = engine.apply(prepare(host, wrong_uid)?, settings(dir))
  assert testing.status_of(refused, host.name, "u") == "failed"
  assert testing.remote_text(host, "id -u -- \"$1\"", [user_name])? == "4322\n"

  let moved = [declare.user_account(id: "u", name: user_name, uid: 4322, shell: "/bin/sh")?]
  let changed = engine.apply(prepare(host, moved)?, settings(dir))
  assert testing.status_of(changed, host.name, "u") == "changed"
  assert testing.remote_text(host, "getent passwd \"$1\" | cut -d: -f7", [user_name])? == "/bin/sh\n"

  let _ = testing.remote_text(host, "echo precious > \"/home/$1/keep\"", [user_name], privileged: true)?
  let removal = [declare.user_account(id: "u", name: user_name, presence: .Absent)?, declare.group_account(id: "g", name: group_name, presence: .Absent, needs: ["u"])?]
  let removed = engine.apply(prepare(host, removal)?, settings(dir))
  assert testing.status_of(removed, host.name, "u") == "changed"
  assert testing.status_of(removed, host.name, "g") == "changed"
  assert testing.remote_text(host, "cat \"/home/$1/keep\"", [user_name], privileged: true)? == "precious\n"
}

test packages_install_check_versions_and_remove_through_apk { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let absent = [declare.package(id: "pkg", name: "jq", presence: .Absent)?]
  let _ = engine.apply(prepare(host, absent)?, settings(dir))
  let wanted = [declare.package(id: "pkg", name: "jq")?]
  let planned = engine.survey(.Plan, prepare(host, wanted)?, settings(dir))
  assert testing.status_of(planned, host.name, "pkg") == "drift"
  assert testing.remote_text(host, "apk info -e jq || echo absent", [])? == "absent\n"

  let first = engine.apply(prepare(host, wanted)?, settings(dir))
  assert testing.status_of(first, host.name, "pkg") == "changed"
  assert testing.remote_text(host, "apk info -e jq", [])? == "jq\n"
  assert testing.status_of(engine.apply(prepare(host, wanted)?, settings(dir)), host.name, "pkg") == "unchanged"

  let at_least = [declare.package(id: "pkg", name: "jq", version: ">=0.1")?]
  assert testing.status_of(engine.survey(.Check, prepare(host, at_least)?, settings(dir)), host.name, "pkg") == "satisfied"
  let too_new = [declare.package(id: "pkg", name: "jq", version: ">=999.0")?]
  assert testing.status_of(engine.survey(.Check, prepare(host, too_new)?, settings(dir)), host.name, "pkg") == "drift"
  let below = [declare.package(id: "pkg", name: "jq", version: "<0.1")?]
  assert testing.status_of(engine.survey(.Check, prepare(host, below)?, settings(dir)), host.name, "pkg") == "drift"

  let removed = engine.apply(prepare(host, absent)?, settings(dir))
  assert testing.status_of(removed, host.name, "pkg") == "changed"
  assert testing.remote_text(host, "apk info -e jq || echo absent", [])? == "absent\n"
}

test a_service_without_an_init_script_is_uncertain_not_unchanged { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let resources = [declare.service(id: "svc", name: "no-such-service", running: true)?]
  let planned = engine.survey(.Plan, prepare(host, resources)?, settings(dir))
  assert testing.status_of(planned, host.name, "svc") == "uncertain"
  let applied = engine.apply(prepare(host, resources)?, settings(dir))
  assert testing.status_of(applied, host.name, "svc") == "failed"
}

const init_script = r"""
#!/sbin/openrc-run
description="xsh-infra test service"
command=/bin/sleep
command_args="3600"
command_background=true
extra_started_commands="reload"
pidfile=/run/${RC_SVCNAME}.pid

reload() {
  echo reload >> /var/tmp/${RC_SVCNAME}.events
}
"""

const default_service_name = "xinfratest"

pure service_resources(marker: Str, enabled: Bool, running: Bool, service_name: Str = default_service_name) -> Result[List[model.Resource], Error] {
  [
    declare.file(id: "init", at: f"/etc/init.d/{service_name}", text: init_script, mode: 0o755)?,
    declare.file(id: "a", at: f"/var/tmp/{service_name}.a", text: marker)?,
    declare.file(id: "b", at: f"/var/tmp/{service_name}.b", text: marker)?,
    declare.service(id: "svc", name: service_name, enabled:, running:, reload_on: ["a", "b"], restart_on: ["init"], needs: ["init"])?,
  ]
}

test an_openrc_service_is_enabled_started_and_reloaded_once_per_apply { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let service_name = default_service_name
  let events = f"/var/tmp/{service_name}.events"
  let _ = testing.remote_text(host, "rc-service \"$1\" stop; rc-update del \"$1\" default; rm -f \"/etc/init.d/$1\" \"/var/tmp/$1\".*; true", [service_name], privileged: true)?
  let first = engine.apply(prepare(host, service_resources("1\n", true, true)?)?, settings(dir))
  assert testing.status_of(first, host.name, "svc") == "changed", report.text(first, true)
  let running = testing.remote_text(host, "rc-service \"$1\" status; ls /etc/runlevels/default", [service_name], privileged: true)?
  assert "started" in running
  assert service_name in running

  let second = engine.apply(prepare(host, service_resources("1\n", true, true)?)?, settings(dir))
  assert testing.status_of(second, host.name, "svc") == "unchanged"

  let third = engine.apply(prepare(host, service_resources("2\n", true, true)?)?, settings(dir))
  assert testing.status_of(third, host.name, "a") == "changed"
  assert testing.status_of(third, host.name, "b") == "changed"
  assert testing.status_of(third, host.name, "svc") == "changed", report.text(third, true)
  assert testing.remote_text(host, "cat \"$1\"", [events], privileged: true)? == "reload\n"

  let down = engine.apply(prepare(host, service_resources("2\n", false, false)?)?, settings(dir))
  assert testing.status_of(down, host.name, "svc") == "changed"
  let state = testing.remote_text(host, "rc-service \"$1\" status 2>&1; ls /etc/runlevels/default", [service_name], privileged: true)?
  assert "stopped" in state
  assert service_name not in state.replace("* status: stopped", with: "")
}

test a_secret_sent_on_stdin_never_appears_in_any_report_even_when_the_command_echoes_it { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  env ({XINFRA_TEST_TOKEN: "correct-horse-battery"}) {
    let resources = [
      declare.command(id: "leak", argv: ["sh", "-c", "cat >&2; exit 3"], always: true, stdin_env: "XINFRA_TEST_TOKEN")?,
    ]
    let prepared = prepare(host, resources)?
    let planned = engine.survey(.Plan, prepared, settings(dir))
    let applied = engine.apply(prepared, settings(dir))
    assert testing.status_of(applied, host.name, "leak") == "failed"
    for result in [planned, applied] {
      for rendered in [report.text(result, true), report.json_document(result)?, report.json_lines(result)?] {
        assert "correct-horse-battery" not in rendered
      }
    }
    assert "***" in report.text(applied, true)
  }
}

test a_package_removed_behind_the_tools_back_is_drift_that_check_reports_and_apply_repairs { |ctx|
  guard let host = fixture("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let wanted = [
    declare.package_index(id: "index")?,
    declare.package(id: "pkg", name: "jq", needs: ["index"])?,
    declare.package(id: "second", name: "tree", needs: ["index"])?,
  ]
  let prepared = prepare(host, wanted)?
  let converged = engine.apply(prepared, settings(dir))
  assert testing.status_of(converged, host.name, "pkg") != "failed", report.text(converged, true)
  assert testing.status_of(converged, host.name, "second") != "failed", report.text(converged, true)
  assert testing.status_of(engine.apply(prepared, settings(dir)), host.name, "pkg") == "unchanged"
  assert testing.status_of(engine.apply(prepared, settings(dir)), host.name, "index") == "changed"

  let _ = testing.remote_text(host, "apk del -q tree", [], privileged: true)?
  let checked = engine.survey(.Check, prepared, settings(dir))
  assert testing.status_of(checked, host.name, "pkg") == "satisfied"
  assert testing.status_of(checked, host.name, "second") == "drift"
  assert testing.status_of(checked, host.name, "index") == "not-evaluated"
  assert testing.remote_text(host, "apk info -e tree || echo absent", [])? == "absent\n"

  let repaired = engine.apply(prepared, settings(dir))
  assert testing.status_of(repaired, host.name, "second") == "changed"
  assert testing.status_of(repaired, host.name, "pkg") == "unchanged"
  assert testing.remote_text(host, "apk info -e tree", [])? == "tree\n"
}

test a_stopped_service_is_drift_repaired_by_apply_and_a_failed_validation_never_restarts_it { |ctx|
  guard let host = fixture("fx-2")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let service_name = "xinfradrift"
  let conf = f"/var/tmp/{service_name}.conf"
  let _ = testing.remote_text(host, "rc-service \"$1\" stop; rc-update del \"$1\" default; rm -f \"/etc/init.d/$1\" \"/var/tmp/$1\".*; true", [service_name], privileged: true)?
  let converged = engine.apply(prepare(host, service_resources("1\n", true, true, service_name)?)?, settings(dir))
  assert testing.status_of(converged, host.name, "svc") == "changed", report.text(converged, true)

  let _ = testing.remote_text(host, "rc-service \"$1\" stop", [service_name], privileged: true)?
  let desired = prepare(host, service_resources("1\n", true, true, service_name)?)?
  let checked = engine.survey(.Check, desired, settings(dir))
  assert testing.status_of(checked, host.name, "svc") == "drift"
  assert "stopped" in testing.remote_text(host, "rc-service \"$1\" status 2>&1 || true", [service_name], privileged: true)?
  let repaired = engine.apply(desired, settings(dir))
  assert testing.status_of(repaired, host.name, "svc") == "changed"
  assert "started" in testing.remote_text(host, "rc-service \"$1\" status 2>&1", [service_name], privileged: true)?
  assert testing.status_of(engine.apply(desired, settings(dir)), host.name, "svc") == "unchanged"

  let events = f"/var/tmp/{service_name}.events"
  let before = testing.remote_text(host, "cat \"$1\" 2>/dev/null || true", [events], privileged: true)?
  let guarded = [
    declare.file(id: "conf", at: conf, text: "bad\n", validate: ["sh", "-c", "exit 1", "validator", "{}"])?,
    declare.service(id: "svc", name: service_name, running: true, reload_on: ["conf"], needs: ["conf"])?,
  ]
  let refused = engine.apply(prepare(host, guarded)?, settings(dir))
  assert testing.status_of(refused, host.name, "conf") == "failed"
  assert testing.status_of(refused, host.name, "svc") == "blocked"
  assert testing.remote_text(host, "cat \"$1\" 2>/dev/null || true", [events], privileged: true)? == before
  assert testing.remote_text(host, "test -e \"$1\" && echo present || echo absent", [conf])? == "absent\n"
}
