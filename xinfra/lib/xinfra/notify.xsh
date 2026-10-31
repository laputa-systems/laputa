##! Coalesced service notifications.

use xinfra.model as model

pure id_of(resource: model.Resource) -> Str {
  match resource {
    model.Directory(spec) => spec.id,
    model.File(spec) => spec.id,
    model.Symlink(spec) => spec.id,
    model.Package(spec) => spec.id,
    model.UserResource(spec) => spec.id,
    model.GroupResource(spec) => spec.id,
    model.CommandResource(spec) => spec.id,
    model.ServiceResource(spec) => spec.id,
  }
}

pure notify_of(resource: model.Resource) -> List[Str] {
  match resource {
    model.Directory(spec) => spec.notify,
    model.File(spec) => spec.notify,
    model.Symlink(spec) => spec.notify,
    model.Package(spec) => spec.notify,
    model.UserResource(spec) => spec.notify,
    model.GroupResource(spec) => spec.notify,
    model.CommandResource(spec) => spec.notify,
    model.ServiceResource(_) => [],
  }
}

## Collect the unique service IDs notified by changed resources.
export pure coalesce(changed: List[Str], resources: List[model.Resource]) -> List[Str] {
  var service_ids = []
  for resource in resources {
    if id_of(resource) in changed {
      for service_id in notify_of(resource) {
        if service_id not in service_ids {
          service_ids += [service_id]
        }
      }
    }
  }
  service_ids
}
