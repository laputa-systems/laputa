##! Production observations and applies over one host at a time.

use xinfra.host as host
use xinfra.inventory as inventory
use xinfra.lock as lock_store
use xinfra.model as model
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

## Open one host session for a multi-action phase.
export proc connect(entry: inventory.Host) -> Result[transport.Session, Error] {
  match transport.connect_endpoint(entry.address, entry.port, entry.user, entry.key, entry.host_key) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
  }
}

proc elevation(session: transport.Session, required: Bool) -> Result[List[Str], Error] {
  let doas = match transport.exec(session, ["doas", "-n", "true"]) {
    Ok(value) => value,
    Err(_) => { return Ok([]) },
  }
  if doas.exit_code == 0 {
    return Ok(["doas", "-n"])
  }

  let sudo = match transport.exec(session, ["sudo", "-n", "true"]) {
    Ok(value) => value,
    Err(_) => { return Ok([]) },
  }
  if sudo.exit_code == 0 {
    return Ok(["sudo", "-n"])
  }

  if required {
    let identity = match transport.exec(session, ["id", "-u"]) {
      Ok(value) => value,
      Err(_) => { return Err(error.failure("cannot determine the remote identity")) },
    }
    if identity.exit_code != 0 or (identity.stdout.utf8() ?? "").trim() != "0" {
      return Err(error.failure("root privilege is required but neither doas nor sudo is available"))
    }
  }
  Ok([])
}

proc unknown(inspection: Result[host.Inspection, Error]) -> plan.Observed {
  match inspection {
    Ok(value) => host.observed(value),
    Err(_) => plan.Unknown,
  }
}

proc observe_on(session: transport.Session, resource: model.Resource) -> Result[plan.Observed, Error] {
  let inspect_elevate = if model.privilege(resource) == model.AsRoot { elevation(session, true)? } else { [] }
  match resource {
    model.Directory(spec) => unknown(remote.inspect_path(session, spec.path, inspect_elevate)),
    model.File(spec) => unknown(remote.inspect_path(session, spec.path, inspect_elevate)),
    model.Symlink(spec) => unknown(remote.inspect_path(session, spec.path, inspect_elevate)),
    model.Package(spec) => match package.fact(session, spec) {
      Ok(value) => value,
      Err(_) => plan.Unknown,
    },
    model.UserResource(spec) => match user_resource.fact(session, spec.name) {
      Ok(value) => value,
      Err(_) => plan.Unknown,
    },
    model.GroupResource(spec) => match group_resource.fact(session, spec.name) {
      Ok(value) => value,
      Err(_) => plan.Unknown,
    },
    model.CommandResource(spec) => match command.observe(session, spec, false, inspect_elevate) {
      Ok(value) => value,
      Err(_) => plan.Unknown,
    },
    model.ServiceResource(spec) => match service.fact(session, spec.name) {
      Ok(value) => value,
      Err(_) => plan.Unknown,
    },
  }
}

## Read one resource fact over a short-lived session.
export proc observe(entry: inventory.Host, resource: model.Resource) -> Result[plan.Observed, Error] {
  with session = connect(entry)? {
    observe_on(session, resource)?
  }
}

## Read every resource fact for one host on one session.
export proc observe_all(entry: inventory.Host, resources: List[model.Resource]) -> Result[Map[Str, plan.Observed], Error] {
  with session = connect(entry)? {
    observe_all_on(session, resources)?
  }
}

## Read a batch of resource facts on one open session.
export proc observe_all_on(session: transport.Session, resources: List[model.Resource]) -> Result[Map[Str, plan.Observed], Error] {
  var observed: Map[Str, plan.Observed] = map.empty()
  for resource in resources {
    let value = observe_on(session, resource)?
    observed = observed.set(model.identity(resource), value)
  }
  Ok(observed)
}

proc apply_one(
  session: transport.Session,
  entry: inventory.Host,
  resource: model.Resource,
  source: validate.PreparedSource?,
  elevate: List[Str],
) -> Result[host.ApplyResult, Error] {
  let resource_elevate = if model.privilege(resource) == model.AsRoot { elevate } else { [] }
  match resource {
    model.Directory(spec) => Ok(dir.apply_remote(session, entry.name, spec, resource_elevate)),
    model.File(spec) => Ok(file.apply_remote(session, entry.name, spec, source, resource_elevate)),
    model.Symlink(spec) => Ok(symlink.apply_remote(session, entry.name, spec, resource_elevate)),
    model.Package(spec) => match package.apply_remote(session, entry.name, spec, resource_elevate) {
      Ok(value) => Ok(value.result),
      Err(failure) => Err(failure),
    }
    model.UserResource(spec) => user_resource.apply_remote(session, entry.name, spec, resource_elevate),
    model.GroupResource(spec) => group_resource.apply_remote(session, entry.name, spec, resource_elevate),
    model.CommandResource(spec) => command.apply_remote(session, entry.name, spec, resource_elevate, true),
    model.ServiceResource(spec) => service.apply_remote(session, entry.name, spec, resource_elevate),
  }
}

## Apply one resource on one open session.
export proc apply_on(
  session: transport.Session,
  entry: inventory.Host,
  resource: model.Resource,
  source: validate.PreparedSource?,
) -> Result[host.ApplyResult, Error] {
  let elevate = if model.privilege(resource) == model.AsRoot { elevation(session, true)? } else { [] }
  apply_one(session, entry, resource, source, elevate)?
}

## Apply one resource over a short-lived session.
export proc apply(
  entry: inventory.Host,
  resource: model.Resource,
  source: validate.PreparedSource?,
) -> Result[host.ApplyResult, Error] {
  with session = connect(entry)? {
    apply_on(session, entry, resource, source)?
  }
}

proc lock_path(session: transport.Session, elevate: List[Str]) -> Result[Path, Error] {
  if ! elevate.is_empty() {
    return Ok(p"/run/xinfra.lock")
  }
  let identity = match transport.exec(session, ["id", "-u"]) {
    Ok(value) => value,
    Err(message) => { return Err(error.failure(message)) },
  }
  if identity.exit_code == 0 and (identity.stdout.utf8() ?? "").trim() == "0" {
    return Ok(p"/run/xinfra.lock")
  }
  let home = match transport.exec(session, ["sh", "-c", "printf %s \"$HOME\""]) {
    Ok(value) => value,
    Err(message) => { return Err(error.failure(message)) },
  }
  if home.exit_code != 0 {
    return Err(error.failure((home.stderr.utf8() ?? "").trim()))
  }
  let directory = (home.stdout.utf8() ?? "").trim()
  if directory == "" {
    return Err(error.failure("remote home directory is unknown"))
  }
  Ok(fp"{directory}/.cache/xinfra/lock")
}

## Acquire one per-host apply lock on one open session.
export proc lock_on(session: transport.Session, entry: inventory.Host, token: Str) -> Result[Unit, Error] {
  let elevate = elevation(session, false)?
  let location = lock_path(session, elevate)?
  let parent = location.parent().display()
  let created = match transport.exec(session, elevate + ["mkdir", "-p", parent]) {
    Ok(value) => value,
    Err(message) => { return Err(error.failure(message)) },
  }
  if created.exit_code != 0 {
    return Err(error.failure((created.stderr.utf8() ?? "").trim()))
  }
  let _ = match lock_store.acquire(session, location, token, entry.name, false, elevate) {
    Ok(value) => value,
    Err(message) => { return Err(error.failure(message)) },
  }
}

## Acquire one per-host apply lock.
export proc lock(entry: inventory.Host, token: Str) -> Result[Unit, Error] {
  with session = connect(entry)? {
    lock_on(session, entry, token)?
  }
}

## Release one per-host apply lock on one open session.
export proc release_lock_on(session: transport.Session, entry: inventory.Host, token: Str) -> Result[Unit, Error] {
  let elevate = elevation(session, false)?
  let location = lock_path(session, elevate)?
  match lock_store.release(session, location, token, elevate) {
    Ok(_) => {}
    Err(message) => { return Err(error.failure(message)) },
  }
}

## Release one per-host apply lock.
export proc release_lock(entry: inventory.Host, token: Str) -> Result[Unit, Error] {
  with session = connect(entry)? {
    release_lock_on(session, entry, token)?
  }
}

## Remove one per-host lock regardless of its owner.
export proc unlock(entry: inventory.Host) -> Result[Unit, Error] {
  with session = connect(entry)? {
    let elevate = elevation(session, false)?
    let location = lock_path(session, elevate)?
    match lock_store.unlock_force(session, location, elevate) {
      Ok(_) => {}
      Err(message) => { return Err(error.failure(message)) },
    }
  }
}

## Apply one coalesced service notification on one open session.
export proc notify_on(session: transport.Session, entry: inventory.Host, spec: model.ServiceSpec) -> Result[host.ApplyResult, Error] {
  let elevate = elevation(session, true)?
  let action = if spec.on_change == model.Reload {
    service.reload_remote(session, spec.name, elevate)?
  } else {
    service.restart_remote(session, spec.name, elevate)?
  }
  if action.status != host.Changed {
    return action
  }
  let observed = service.fact(session, spec.name)?
  match observed {
    plan.Running(facts) => {
      if facts.started {
        host.ApplyResult(
          id: action.id,
          host: action.host,
          status: host.Changed,
          verified: true,
          cause: action.cause,
        )
      } else {
        host.ApplyResult(
          id: action.id,
          host: action.host,
          status: host.Partial,
          verified: false,
          cause: "service did not start after the notification",
        )
      }
    }
    _ => host.ApplyResult(
      id: action.id,
      host: action.host,
      status: host.Unknown,
      verified: false,
      cause: "service state is unknown after the notification",
    ),
  }
}

## Apply one coalesced service notification over a short-lived session.
export proc notify(entry: inventory.Host, spec: model.ServiceSpec) -> Result[host.ApplyResult, Error] {
  with session = connect(entry)? {
    notify_on(session, entry, spec)?
  }
}
