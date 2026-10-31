##! Dependency validation and stable ordering for xinfra resources.

use xinfra.model

## Sorts resources so every prerequisite precedes its dependents.
export pure sort(resources: List[model.Resource]) -> Result[List[model.Resource], model.Problem] {
  var seen: Set[Str] = set.empty()
  for resource in resources {
    let id = model.identity(resource)
    if id in seen {
      return Err(
        model.Problem(kind: "duplicate-id", id: id, field: "id", message: f"duplicate resource id {id}"),
      )
    }

    seen = seen.add(id)
  }

  for resource in resources {
    let id = model.identity(resource)
    for requirement in model.requirements(resource) {
      if ! (requirement in seen) {
        return Err(
          model.Problem(
            kind: "unknown-requirement",
            id: id,
            field: "requires",
            message: f"resource {id} requires unknown resource {requirement}",
          ),
        )
      }
    }
  }

  var indegree: Map[Str, Int] = map.empty()
  var dependents: Map[Str, List[Str]] = map.empty()
  for resource in resources {
    let id = model.identity(resource)
    indegree = indegree.set(id, 0)
  }

  for resource in resources {
    let id = model.identity(resource)
    for requirement in model.requirements(resource) {
      indegree = indegree.set(id, (indegree.get(id) ?? 0) + 1)
      let downstream: List[Str] = dependents.get(requirement) ?? []
      dependents = dependents.set(requirement, downstream + [id])
    }
  }

  var emitted: Set[Str] = set.empty()
  var ordered: List[model.Resource] = []
  var changed = true
  while changed {
    changed = false
    for resource in resources {
      let id = model.identity(resource)
      if ! (id in emitted) and (indegree.get(id) ?? 0) == 0 {
        ordered += [resource]
        emitted = emitted.add(id)
        changed = true
        let downstream: List[Str] = dependents.get(id) ?? []
        for dependent in downstream {
          indegree = indegree.set(dependent, (indegree.get(dependent) ?? 0) - 1)
        }
      }
    }
  }

  if ordered.len() != resources.len() {
    var blocked: List[Str] = []
    for resource in resources {
      let id = model.identity(resource)
      if ! (id in emitted) {
        blocked += [id]
      }
    }

    return Err(
      model.Problem(
        kind: "dependency-cycle",
        field: "requires",
        message: f"dependency cycle among {blocked.join(", ")}",
      ),
    )
  }

  Ok(ordered)
}
