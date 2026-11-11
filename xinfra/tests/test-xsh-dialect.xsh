use infra.declare
use infra.engine
use infra.fact
use infra.lock
use infra.model
use infra.probe
use infra.report
use infra.scripts
use infra.shell
use infra.testing
use infra.transport
use infra.workload

const hostile = ["plain", "", "-x", "--", "it's", "a b", "line\nbreak", "$HOME", "$(echo injected)", "`id`", "; id", "*", "\\", "caf\u{e9}", "\u{1f980}"]

const fake_xinit = r"""
#!/bin/sh
dir=$XINIT_FAKE_DIR
name=$2
state=down
if [ -f "$dir/$name.state" ]; then state=$(cat "$dir/$name.state"); fi
if [ "$1" = status ]; then
  if [ "$name" = sealed ]; then
    echo 'xinit: /run/xinit: Permission denied' >&2
    exit 1
  fi
  if [ "$state" = running ]; then ready=true; else ready=false; fi
  printf '%s %s pid=1 ready=%s log=append desired=up restarts=0\n' "$name" "$state" "$ready"
  exit 0
fi
printf '%s %s\n' "$1" "$name" >> "$dir/actions.log"
case $1 in
  start) printf 'running\n' > "$dir/$name.state" ;;
  stop) printf 'down\n' > "$dir/$name.state" ;;
  restart) printf 'running\n' > "$dir/$name.state" ;;
  reload) ;;
  *) echo "unexpected action $1" >&2; exit 64 ;;
esac
"""

proc xinit_fixture(dir: Path) [fs, error] {
  let bin = fp"{dir}/bin"
  bin.mkdir()
  let fake = fp"{bin}/xinit"
  fake.write(fake_xinit)
  fake.chmod(0o755)
  let services = fp"{dir}/services"
  services.mkdir()
  for name in ["logger", "sealed"] {
    fp"{services}/{name}.xsh".write("service\n")
  }
}

proc connect(host: model.Host) [fs, process, error] -> Result[transport.Connection, transport.TransportError] {
  transport.connect(host)
}

pure path_description(state: fact.PathState) -> Str {
  match state {
    fact.Missing => "missing"
    fact.Blocked(reason) => f"blocked {reason.cause}"
    fact.Unseen(reason) => f"unseen {reason.cause} {reason.detail}"
    fact.Found(info) => f"found {info.kind} {info.mode} {info.uid} {info.gid} {info.owner} {info.group} {info.size} {info.digest ?? "-"} {info.link_target ?? "-"}"
  }
}

pure service_description(state: fact.ServiceState) -> Str {
  match state {
    fact.NoService => "missing"
    fact.ServiceUnseen(reason) => f"unseen {reason.cause}"
    fact.ServiceFound(info) => f"found {info.enabled ?? false} {info.running} {info.ready ?? false}"
  }
}

proc path_from(connection: transport.Connection, target: Str) [fs, process, error] -> Result[fact.PathState, Error] {
  let execution = transport.exec(connection, .PathState, [target])?
  guard execution.code == 0 else {
    fail f"path state exited {execution.code}: {execution.stderr.utf8() ?? ""}"
  }

  Ok(probe.path_fact(execution.stdout.utf8()?))
}

test the_xsh_dialect_round_trips_hostile_arguments_as_literals {
  let connection = connect(testing.local_xsh_host())?
  let result = transport.exec(connection, .EchoArguments, hostile)?
  assert result.code == 0
  let expected = hostile |> map { |word| word + "\0" } |> collect()
  assert result.stdout.utf8()? == expected.join("")
}

test posix_operations_still_resolve_to_the_original_constants {
  assert scripts.source(.Posix, .PathState)? == scripts.path_state
  assert scripts.source(.Posix, .XinitServiceState)? == scripts.xinit_service_state
  assert scripts.source(.Posix, .CreateStage)? == scripts.create_stage
  assert scripts.source(.Posix, .AcquireLock)? == scripts.acquire_lock
  let rendered = shell.command(scripts.source(.Posix, .PathState)?, ["/tmp/x"])?
  assert rendered == f"/bin/sh -c {shell.quote(scripts.path_state)?} xinfra '/tmp/x'"
}

test xsh_source_is_never_rendered_as_a_posix_command_string {
  let source = scripts.source(.Xsh, .PathState)?
  let rendered = shell.xsh_command(source, ["/tmp/x"])?
  assert rendered.starts_with("let xinfra_args: List[Str] = [\"/tmp/x\"]\n")
  assert "/bin/sh -c" not in rendered
  assert shell.command(scripts.source(.Posix, .PathState)?, ["/tmp/x"])?.starts_with("/bin/sh -c ") == true
  assert shell.xsh_quote("a\0b") is Err(_)
}

test a_dialect_missing_an_operation_is_a_typed_refusal_not_the_posix_script {
  match scripts.source(.Xsh, .PackageState) {
    Err(scripts.ScriptError.Missing {dialect, operation, message}) => {
      assert dialect == .Xsh
      assert operation == .PackageState
      assert "no script for package-state" in message
    }
    else => assert false, "an xsh package probe resolved"
  }

  assert scripts.source(.Posix, .PackageState) is Ok(_)
  assert scripts.supports(.Xsh, .PathState)
  assert ! scripts.supports(.Xsh, .PackageState)
  assert ! scripts.supports(.Xsh, .RunShell)

  let connection = connect(testing.local_xsh_host())?
  match transport.exec(connection, .RunShell, ["echo hi"]) {
    Err(transport.TransportError.Refused {message}) => assert "no script for run-shell" in message
    else => assert false, "a missing xsh script fell back to a shell"
  }

  match transport.exec_script(connection, "echo hi") {
    Err(transport.TransportError.Refused {message}) => assert "raw POSIX script" in message
    else => assert false, "a raw POSIX script ran on an xsh target"
  }
}

test workload_refuses_a_resource_kind_the_xsh_dialect_has_no_script_for {
  let resources = [declare.package(id: "jq", name: "jq")?]
  match workload.prepare([workload.Workload(host: testing.local_xsh_host(), resources:)]) {
    Err(error) => {
      assert "no script for package-state" in error.message
      assert "package resource" in error.message
    }
    Ok(_) => assert false, "an xsh host accepted a package resource"
  }
}

test the_xsh_path_script_reports_the_same_facts_as_the_posix_script { |ctx|
  let dir = test.temp_dir(ctx)?
  let root = fp"{dir}/tree"
  root.mkdir()
  let file = fp"{root}/motd"
  file.write("hello\n")
  file.chmod(0o640)
  let link = fp"{root}/current"
  fs.symlink(p"motd", link)?
  let blocker = fp"{root}/blocker"
  blocker.write("x")

  let posix = connect(testing.local_host())?
  let xsh = connect(testing.local_xsh_host())?
  for target in [f"{file}", f"{root}", f"{link}", f"{root}/missing", f"{blocker}/below"] {
    let expected = path_from(posix, target)?
    let actual = path_from(xsh, target)?
    assert path_description(actual) == path_description(expected), f"{target}: {path_description(actual)} != {path_description(expected)}"
  }
}

test the_xsh_xinit_probe_reports_the_same_service_facts_as_the_posix_script { |ctx|
  let dir = test.temp_dir(ctx)?
  xinit_fixture(dir)?
  let search = env.get("PATH")?
  env ({PATH: f"{dir}/bin:{search}", XINIT_SERVICE_DIR: f"{dir}/services", XINIT_FAKE_DIR: f"{dir}"}) {
    let posix = connect(testing.local_host())?
    let xsh = connect(testing.local_xsh_host())?
    fp"{dir}/logger.state".write("running\n")
    for name in ["logger", "sealed", "ghost"] {
      let expected = transport.exec(posix, .XinitServiceState, [name])?
      let actual = transport.exec(xsh, .XinitServiceState, [name])?
      assert expected.code == 0 and actual.code == 0
      let actual_text = actual.stdout.utf8()?
      assert service_description(probe.xinit_service_fact(actual_text)) == service_description(probe.xinit_service_fact(expected.stdout.utf8()?)), f"{name}: {actual_text}"
    }
  }
}

test an_xsh_file_validation_failure_discards_the_stage { |ctx|
  let dir = test.temp_dir(ctx)?
  let target = fp"{dir}/validated"
  let resources = [declare.file(id: "validated", at: f"{target}", text: "bad\n", validate: ["/bin/false", "{}"])?]
  let prepared = workload.prepare([workload.Workload(host: testing.local_xsh_host(), resources:)])?
  let applied = engine.apply(prepared, settings(dir))
  assert statuses(applied, "local-xsh", ["validated"]) == ["failed"]
  assert ! target.exists()?
  let leftovers = fs.children(dir)? |> where { |child| child.name.starts_with(".xinfra.") } |> count()
  assert leftovers == 0
}

test a_relative_lock_path_resolves_against_the_remote_cwd { |ctx|
  let dir = test.temp_dir(ctx)?
  let connection = connect(testing.local_xsh_host())?
  cd (dir) {
    let held = lock.acquire(connection, "xinfra.lock")?
    assert held.token.byte_len() == 32
    assert lock.inspect(connection, "xinfra.lock")? != null
    lock.release(connection, held)?
    assert lock.inspect(connection, "xinfra.lock")? == null
  }
}

test the_xsh_capability_probe_reports_the_running_identity {
  let connection = connect(testing.local_xsh_host())?
  let execution = transport.exec(connection, .Capabilities)?
  assert execution.code == 0
  let found = probe.capabilities(execution.stdout.utf8()?)?
  assert found.uid == user.current()?.uid
  assert "xinit" in found.present or "xinit" in found.absent
}

proc settings(dir: Path) -> engine.Settings {
  engine.Settings(jobs: 1, policy: .Host, lock_path: f"{dir}/.lock-{{host}}")
}

pure statuses(result: report.Report, host: Str, ids: List[Str]) -> List[Str] {
  ids |> map { |id| testing.status_of(result, host, id) } |> collect()
}

pure generated_statuses(result: report.Report, ids: List[Str]) -> List[Str] {
  ids |> map { |id| testing.status_of(result, "local-xsh", id) } |> collect()
}

proc actions(dir: Path) [fs] -> List[Str] {
  (fp"{dir}/actions.log".read_text() ?? "").lines()
}

test a_local_xsh_host_converges_file_directory_link_command_and_service_and_reruns_unchanged { |ctx|
  let dir = test.temp_dir(ctx)?
  xinit_fixture(dir)?
  let search = env.get("PATH")?
  env ({PATH: f"{dir}/bin:{search}", XINIT_SERVICE_DIR: f"{dir}/services", XINIT_FAKE_DIR: f"{dir}"}) {
    let site = fp"{dir}/site"
    let stamp = fp"{dir}/stamp"
    let account = env.get("USER")?
    let account_id = f"{user.current()?.uid}"
    let resources = [
      declare.directory(id: "root", at: f"{site}", mode: 0o750, owner: account)?,
      declare.file(id: "motd", at: f"{site}/motd", text: "hello xsh\n", mode: 0o640, owner: account_id, needs: ["root"])?,
      declare.symlink(id: "current", at: f"{site}/current", target: "motd", needs: ["motd"])?,
      declare.command(id: "stamp", argv: ["touch", f"{stamp}"], creates: f"{stamp}", needs: ["root"])?,
      declare.xinit_service(id: "logger", name: "logger", running: true, restart_on: ["motd"])?,
    ]
    let prepared = workload.prepare([workload.Workload(host: testing.local_xsh_host(), resources:)])?
    let ids = ["root", "motd", "current", "stamp", "logger"]
    let first = engine.apply(prepared, settings(dir))
    assert statuses(first, "local-xsh", ids) == ["changed", "changed", "changed", "changed", "changed"]
    assert report.exit_status(first) == 0
    assert fp"{site}/motd".read_text()? == "hello xsh\n"
    assert fp"{site}/current".readlink()? == p"motd"
    assert actions(dir) == ["start logger"]

    let second = engine.apply(prepared, settings(dir))
    assert statuses(second, "local-xsh", ids) == ["unchanged", "unchanged", "unchanged", "skipped", "unchanged"]
    assert actions(dir) == ["start logger"]

    fp"{site}/motd".write("changed\n")
    let third = engine.apply(prepared, settings(dir))
    assert statuses(third, "local-xsh", ids) == ["unchanged", "changed", "unchanged", "skipped", "changed"]
    assert actions(dir) == ["start logger", "restart logger"]

    let retarget = [
      declare.directory(id: "root", at: f"{site}", mode: 0o750, owner: account)?,
      declare.file(id: "motd", at: f"{site}/motd", text: "hello xsh\n", mode: 0o640, owner: account_id, needs: ["root"])?,
      declare.symlink(id: "current", at: f"{site}/current", target: "elsewhere", replace: true, needs: ["motd"])?,
      declare.xinit_service(id: "logger", name: "logger", running: true, restart_on: ["motd"])?,
    ]
    let updated = engine.apply(workload.prepare([workload.Workload(host: testing.local_xsh_host(), resources: retarget)])?, settings(dir))
    assert generated_statuses(updated, ["root", "motd", "current", "logger"]) == ["unchanged", "unchanged", "changed", "unchanged"]
    assert fp"{site}/current".readlink()? == p"elsewhere"

    let absent = [
      declare.symlink(id: "current", at: f"{site}/current", presence: .Absent)?,
      declare.file(id: "motd", at: f"{site}/motd", presence: .Absent)?,
      declare.directory(id: "root", at: f"{site}", presence: .Absent)?,
    ]
    let cleaned = engine.apply(workload.prepare([workload.Workload(host: testing.local_xsh_host(), resources: absent)])?, settings(dir))
    assert generated_statuses(cleaned, ["current", "motd", "root"]) == ["changed", "changed", "changed"]
    assert report.exit_status(cleaned) == 0
    assert ! site.exists()?
  }
}
