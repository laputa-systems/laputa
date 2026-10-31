##! Complete Alpine web example over the remote resource layer.

use xinfra.host as host
use xinfra.inventory as inventory
use xinfra.model as model
use xinfra.notify as notify
use xinfra.plan as plan
use xinfra.remote as remote
use xinfra.resources.command as command
use xinfra.resources.dir as dir
use xinfra.resources.file as file
use xinfra.resources.group as group_resource
use xinfra.resources.package as package
use xinfra.resources.service as service
use xinfra.resources.symlink as symlink
use xinfra.resources.user as user_resource
use xinfra.transport as transport
use xinfra.validate as validate

type Fixture = {host: Str, port: Int, username: Str, key: Path, host_key: Str}

proc required(name: Str) [env, error] -> Result[Str, Error] {
  match env.get(name) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.failure(f"missing {name}: {error.message}")),
  }
}

proc fixture(suffix: Str) [env, error] -> Result[Fixture, Error] {
  let host = required(f"XINFRA_FIXTURE_{suffix}_HOST")?
  let port_text = required(f"XINFRA_FIXTURE_{suffix}_PORT")?
  let port = match port_text.parse_int() {
    Ok(value) => value,
    Err(error) => { return Err(error) },
  }
  let username = required("XINFRA_FIXTURE_USER")?
  let key_text = required("XINFRA_FIXTURE_KEY")?
  let host_key = required(f"XINFRA_FIXTURE_{suffix}_HOST_KEY")?
  Ok({host: host, port: port, username: username, key: fp"{key_text}", host_key: host_key})
}

proc require(condition: Bool, message: Str) -> Result[Unit, Error] {
  if condition { Ok() } else { Err(error.failure(message)) }
}

proc connect(fixture: Fixture) -> Result[transport.Session, Error] {
  match transport.connect_endpoint(fixture.host, fixture.port, fixture.username, fixture.key, fixture.host_key) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
  }
}

proc execute(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Error] {
  match transport.exec(session, argv) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
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

proc reset(session: transport.Session, elevate: List[Str]) -> Result[Unit, Error] {
  let _ = execute(session, [@elevate, "rc-service", "nginx", "stop"])?
  let _ = execute(session, [@elevate, "rc-update", "del", "nginx", "default"])?
  let _ = execute(session, [@elevate, "apk", "del", "nginx"])?
  let _ = execute(session, [@elevate, "userdel", "webapp"])?
  let _ = execute(session, [@elevate, "groupdel", "webapp"])?
  let _ = execute(session, [@elevate, "rm", "-rf", "/etc/nginx", "/var/www", "/etc/motd"])?
  Ok()
}

proc source_for(deployment: validate.Deployment, id: Str) -> validate.PreparedSource? {
  match deployment.sources.get(id) {
    Ok(value) => value,
    Err(_) => null,
  }
}

proc inspect(session: transport.Session, target: Path) -> Result[host.Inspection, Error] {
  remote.inspect_path(session, target)
}

proc observe(session: transport.Session, resource: model.Resource) -> Result[plan.Observed, Error] {
  match resource {
    model.Directory(spec) => {
      let inspection = inspect(session, spec.path)?
      Ok(host.observed(inspection))
    }
    model.File(spec) => {
      let inspection = inspect(session, spec.path)?
      Ok(host.observed(inspection))
    }
    model.Symlink(spec) => {
      let inspection = inspect(session, spec.path)?
      Ok(host.observed(inspection))
    }
    model.Package(spec) => package.fact(session, spec),
    model.UserResource(spec) => user_resource.fact(session, spec.name),
    model.GroupResource(spec) => group_resource.fact(session, spec.name),
    model.CommandResource(spec) => command.observe(session, spec, false),
    model.ServiceResource(spec) => service.fact(session, spec.name),
  }
}

proc apply_one(
  session: transport.Session,
  host_name: Str,
  resource: model.Resource,
  source: validate.PreparedSource?,
  elevate: List[Str],
) -> Result[host.ApplyResult, Error] {
  let resource_elevate = if model.privilege(resource) == model.AsRoot { elevate } else { [] }
  match resource {
    model.Directory(spec) => Ok(dir.apply_remote(session, host_name, spec, resource_elevate)),
    model.File(spec) => Ok(file.apply_remote(session, host_name, spec, source, resource_elevate)),
    model.Symlink(spec) => Ok(symlink.apply_remote(session, host_name, spec, resource_elevate)),
    model.Package(spec) => match package.apply_remote(session, host_name, spec, resource_elevate) {
      Ok(value) => Ok(value.result),
      Err(failure) => Err(failure),
    }
    model.UserResource(spec) => user_resource.apply_remote(session, host_name, spec, resource_elevate),
    model.GroupResource(spec) => group_resource.apply_remote(session, host_name, spec, resource_elevate),
    model.CommandResource(spec) => command.apply_remote(session, host_name, spec, resource_elevate, true),
    model.ServiceResource(spec) => service.apply_remote(session, host_name, spec, resource_elevate),
  }
}

proc apply_all(
  session: transport.Session,
  host_name: Str,
  deployment: validate.Deployment,
  elevate: List[Str],
) -> Result[List[host.ApplyResult], Error] {
  var results: List[host.ApplyResult] = []
  for resource in deployment.resources {
    let id = model.identity(resource)
    let result = apply_one(session, host_name, resource, source_for(deployment, id), elevate)?
    results += [result]
  }

  var changed: List[Str] = []
  for result in results {
    if result.status == host.Changed {
      changed += [result.id]
    }
  }
  for service_id in notify.coalesce(changed, deployment.resources) {
    for resource in deployment.resources {
      match resource {
        model.ServiceResource(spec) => {
          if spec.id == service_id {
            let notification = if spec.on_change == model.Reload {
              service.reload_remote(session, spec.name, elevate)?
            } else {
              service.restart_remote(session, spec.name, elevate)?
            }
            let _ = notification
          }
        }
        _ => {}
      }
    }
  }
  Ok(results)
}

## Execute the complete example scenario.
export proc check_example() [fs, process, env, error, io] -> Result[Unit, Error] {
  let a = fixture("A")?
  let root = fs.gitroot()?
  let inventory_value = inventory.Inventory(
    groups: ["web"],
    hosts: [
      inventory.Host(
        name: "xinfra-a",
        groups: ["web"],
        address: a.host,
        port: a.port.require(inventory.Port)?,
        user: a.username,
        key: a.key,
        host_key: a.host_key,
      ),
    ],
  )
  let deployment = match validate.load(fp"{root}/examples/alpine-web/deploy.xsh", inventory_value, root) {
    Ok(value) => value,
    Err(problem) => {
      return Err(error.failure(f"{problem.kind}: {problem.message}"))
    }
  }

  with session = connect(a)? {
    let elevate = ["doas", "-n"]
    reset(session, elevate)?

    let first = apply_all(session, "xinfra-a", deployment, elevate)?
    for result in first {
      if result.status != host.Changed or ! result.verified {
        return Err(error.failure(f"first example apply failed for {result.id}: {status_name(result.status)} {result.cause ?? ""}"))
      }
    }
    print test_case("first apply")

    let second = apply_all(session, "xinfra-a", deployment, elevate)?
    for result in second {
      if result.status != host.Unchanged {
        return Err(error.failure(f"second example apply changed {result.id}: {status_name(result.status)} {result.cause ?? ""}"))
      }
    }
    print test_case("second apply is a no-op")

    let config_path = p"/etc/nginx/nginx.conf"
    let before = inspect(session, config_path)?
    for resource in deployment.resources {
      let source = source_for(deployment, model.identity(resource))
      let observed = observe(session, resource)?
      let assessment = plan.assess(resource, source, observed)
      if assessment.prediction != plan.Unchanged {
        return Err(error.failure(f"plan did not predict unchanged for {model.identity(resource)}"))
      }
    }
    let after = inspect(session, config_path)?
    require(before == after, "plan or check mutated the nginx config")?
    print test_case("plan and check perform no write")

    let _ = execute(session, [@elevate, "sh", "-c", f"printf '\\n# drift\\n' >> {config_path.display()}"])?
    let drifted = apply_all(session, "xinfra-a", deployment, elevate)?
    let config_results = drifted |> where { |result| result.id == "nginx-config" }
    require(! config_results.is_empty(), "drift result is missing")?
    let config_result = config_results[0]
    require(config_result.status == host.Changed and config_result.verified, "drift was not repaired")?
    let repaired = inspect(session, config_path)?
    match repaired {
      host.Found(stat) => {
        let expected = source_for(deployment, "nginx-config") ?? validate.Secret(model.FromEnv(""))
        require(stat.digest == (validate.digest(expected) ?? ""), "repaired config digest differs")?
      }
      host.Missing => return Err(error.failure("repaired config is missing")),
    }
    print test_case("drift detection and repair")

    let running = service.fact(session, "nginx")?
    match running {
      plan.Running(facts) => require(facts.started and facts.enabled == true, "nginx is not started and enabled")?,
      _ => return Err(error.failure("nginx service state is unknown")),
    }
    print test_case("service stays started and enabled")

    reset(session, elevate)?
  }

  Ok()
}
