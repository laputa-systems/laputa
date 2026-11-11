use infra.declare
use infra.engine
use infra.model
use infra.report
use infra.testing
use infra.workload

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

proc fixture(dir: Path) [fs, error] {
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

proc settings(dir: Path) -> engine.Settings {
  engine.Settings(jobs: 1, policy: .Host, lock_path: f"{dir}/.lock-{{host}}")
}

proc prepared(resources: List[model.Resource]) [fs, env, error] -> Result[workload.Prepared, Error] {
  workload.prepare([workload.Workload(host: testing.local_host(), resources:)])
}

proc actions(dir: Path) [fs] -> List[Str] {
  (fp"{dir}/actions.log".read_text() ?? "").lines()
}

pure statuses(result: report.Report, ids: List[Str]) -> List[Str] {
  ids |> map { |id| testing.status_of(result, "local", id) } |> collect()
}

test an_xinit_service_starts_restarts_and_stops_through_the_control_plane { |ctx|
  let dir = test.temp_dir(ctx)?
  fixture(dir)?
  let trigger = fp"{dir}/trigger"
  let search = env.get("PATH")?
  env ({PATH: f"{dir}/bin:{search}", XINIT_SERVICE_DIR: f"{dir}/services", XINIT_FAKE_DIR: f"{dir}"}) {
    let running = [
      declare.file(id: "trigger", at: f"{trigger}", text: "one\n", mode: 0o600)?,
      declare.xinit_service(id: "logger", name: "logger", running: true, restart_on: ["trigger"])?,
    ]
    let first = engine.apply(prepared(running)?, settings(dir))
    assert statuses(first, ["trigger", "logger"]) == ["changed", "changed"]
    assert report.exit_status(first) == 0
    assert actions(dir) == ["start logger"]

    let second = engine.apply(prepared(running)?, settings(dir))
    assert statuses(second, ["trigger", "logger"]) == ["unchanged", "unchanged"]
    assert actions(dir) == ["start logger"]

    trigger.write("two\n")
    let drifted = engine.apply(prepared(running)?, settings(dir))
    assert statuses(drifted, ["trigger", "logger"]) == ["changed", "changed"]
    assert actions(dir) == ["start logger", "restart logger"]

    let stopped = [declare.xinit_service(id: "logger", name: "logger", running: false)?]
    let down = engine.apply(prepared(stopped)?, settings(dir))
    assert statuses(down, ["logger"]) == ["changed"]
    assert actions(dir) == ["start logger", "restart logger", "stop logger"]

    let stable = engine.apply(prepared(stopped)?, settings(dir))
    assert statuses(stable, ["logger"]) == ["unchanged"]
  }
}

test an_unknown_xinit_service_is_uncertain_and_never_controlled { |ctx|
  let dir = test.temp_dir(ctx)?
  fixture(dir)?
  let search = env.get("PATH")?
  env ({PATH: f"{dir}/bin:{search}", XINIT_SERVICE_DIR: f"{dir}/services", XINIT_FAKE_DIR: f"{dir}"}) {
    let resources = [declare.xinit_service(id: "ghost", name: "ghost", running: true)?]
    let planned = engine.survey(.Plan, prepared(resources)?, settings(dir))
    assert statuses(planned, ["ghost"]) == ["uncertain"]
    let applied = engine.apply(prepared(resources)?, settings(dir))
    assert statuses(applied, ["ghost"]) == ["failed"]
    assert actions(dir).is_empty()
  }
}

test an_unreadable_xinit_status_is_uncertain_not_down { |ctx|
  let dir = test.temp_dir(ctx)?
  fixture(dir)?
  let search = env.get("PATH")?
  env ({PATH: f"{dir}/bin:{search}", XINIT_SERVICE_DIR: f"{dir}/services", XINIT_FAKE_DIR: f"{dir}"}) {
    let resources = [declare.xinit_service(id: "sealed", name: "sealed", running: true)?]
    let planned = engine.survey(.Plan, prepared(resources)?, settings(dir))
    assert statuses(planned, ["sealed"]) == ["uncertain"]
    guard let entry = testing.entry_of(planned, "local", "sealed") else {
      assert false, "no entry"
      return
    }

    assert entry.phase == "observe"
    assert "denied" in (entry.detail ?? "")
    let applied = engine.apply(prepared(resources)?, settings(dir))
    assert statuses(applied, ["sealed"]) == ["failed"]
    assert actions(dir).is_empty()
  }
}
