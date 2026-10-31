##! Remote OpenRC service matrix.

use xinfra.host as host
use xinfra.model as model
use xinfra.notify as notify
use xinfra.plan as plan
use xinfra.resources.service as service
use xinfra.transport as transport

type Fixture = {
  host: Str,
  port: Int,
  username: Str,
  key: Path,
  host_key: Str,
}

proc required(name: Str) [env, error] -> Result[Str, Str] {
  match env.get(name) {
    Ok(value) => Ok(value),
    Err(error) => Err(f"missing {name}: {error.message}"),
  }
}

proc fixture(suffix: Str) [env, error] -> Result[Fixture, Str] {
  let host = required(f"XINFRA_FIXTURE_{suffix}_HOST")?
  let port_text = required(f"XINFRA_FIXTURE_{suffix}_PORT")?
  let port = match port_text.parse_int() {
    Ok(value) => value,
    Err(error) => { return Err(error.message) },
  }
  let username = required("XINFRA_FIXTURE_USER")?
  let key_text = required("XINFRA_FIXTURE_KEY")?
  let host_key = required(f"XINFRA_FIXTURE_{suffix}_HOST_KEY")?
  Ok({host: host, port: port, username: username, key: fp"{key_text}", host_key: host_key})
}

proc require(condition: Bool, message: Str) -> Result[Unit, Str] {
  if condition {
    Ok()
  } else {
    Err(message)
  }
}

proc connect(fixture: Fixture) [error] -> Result[transport.Session, Str] {
  transport.connect_endpoint(
    fixture.host,
    fixture.port,
    fixture.username,
    fixture.key,
    fixture.host_key,
  )
}

proc execute(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Str] {
  transport.exec(session, argv)
}

proc apply(
  session: transport.Session,
  host_name: Str,
  spec: model.ServiceSpec,
  elevate: List[Str],
) -> Result[host.ApplyResult, Str] {
  match service.apply_remote(session, host_name, spec, elevate) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

proc fact(session: transport.Session, name: Str) -> Result[plan.Observed, Str] {
  match service.fact(session, name) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

proc restart(session: transport.Session, name: Str, elevate: List[Str]) -> Result[host.ApplyResult, Str] {
  match service.restart_remote(session, name, elevate) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

pure status_name(status: host.ApplyStatus) -> Str {
  if status == host.Changed { return "changed" }
  if status == host.Unchanged { return "unchanged" }
  if status == host.Failed { return "failed" }
  if status == host.Partial { return "partial" }
  if status == host.Blocked { return "blocked" }
  if status == host.Unknown { return "unknown" }
  "other"
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the service and notification matrix.
export proc check_services() [fs, process, env, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?
  let name = "xinfra-r5"
  let log = p"/tmp/xinfra-r5.log"
  let script = r"""
#!/sbin/openrc-run
name="xinfra-r5"
start() { touch /run/xinfra-r5.started; echo start >> /tmp/xinfra-r5.log; }
stop() { rm -f /run/xinfra-r5.started; echo stop >> /tmp/xinfra-r5.log; }
status() { [ -f /run/xinfra-r5.started ] && exit 0 || exit 3; }
restart() { touch /run/xinfra-r5.started; echo restart >> /tmp/xinfra-r5.log; }
"""

  with session = connect(a)? {
    let elevate = ["sudo", "-n"]
    let _ = execute(session, [@elevate, "rc-service", name, "stop"])?
    let _ = execute(session, [@elevate, "rc-update", "del", name, "default"])?
    let _ = execute(session, [@elevate, "rm", "-f", f"/etc/init.d/{name}", log.display(), f"/run/{name}.started"])?

    let staged = p"/tmp/xinfra-r5.init"
    let _ = transport.write_bytes(session, staged, bytes.from_text(script))?
    let _ = execute(session, [@elevate, "mv", staged.display(), f"/etc/init.d/{name}"])?
    let _ = execute(session, [@elevate, "chmod", "755", f"/etc/init.d/{name}"])?

    let started = model.ServiceSpec(id: name, name: name, state: model.Started, enabled: true)
    let first = apply(session, a.host, started, elevate)?
    require(first.status == host.Changed and first.verified, f"service start failed: {status_name(first.status)} {first.cause ?? ""}")?
    let second = apply(session, a.host, started, elevate)?
    require(second.status == host.Unchanged, "second service apply was not unchanged")?
    match fact(session, name)? {
      plan.Running(facts) => {
        require(facts.started, "service is not started")?
        require(facts.enabled == true, "service is not enabled")?
      }
      _ => return Err("service fact is unknown"),
    }
    print test_case("service start, enable, and unchanged")

    let stopped = model.ServiceSpec(id: name, name: name, state: model.Stopped, enabled: false)
    let stop_result = apply(session, a.host, stopped, elevate)?
    require(stop_result.status == host.Changed, "service stop failed")?
    match fact(session, name)? {
      plan.Running(facts) => require(! facts.started and facts.enabled == false, "service did not stop and disable")?,
      _ => return Err("stopped service fact is unknown"),
    }
    print test_case("service stop and disable")

    let files = [
      model.File(model.FileSpec(id: "one", path: p"/tmp/xinfra-r5-one", notify: [name])),
      model.File(model.FileSpec(id: "two", path: p"/tmp/xinfra-r5-two", notify: [name])),
    ]
    let service_ids = notify.coalesce(["one", "two"], files)
    require(service_ids.len() == 1 and service_ids[0] == name, "several changed files were not coalesced")?
    let _ = execute(session, [@elevate, "sh", "-c", f": > {log.display()}"])?
    let restarted = restart(session, name, elevate)?
    require(restarted.status == host.Changed, "coalesced restart failed")?
    let logged = execute(session, ["cat", log.display()])?
    let restarts = (logged.stdout.utf8() ?? "").lines() |> where { |line| line == "restart" or line == "start" } |> count()
    require(restarts == 1, "service restarted more than once")?
    print test_case("coalesced restart once")

    let _ = execute(session, [@elevate, "rc-service", name, "stop"])?
    let _ = execute(session, [@elevate, "rc-update", "del", name, "default"])?
    let _ = execute(session, [@elevate, "rm", "-f", f"/etc/init.d/{name}", log.display(), f"/run/{name}.started"])?
  }

  Ok()
}
