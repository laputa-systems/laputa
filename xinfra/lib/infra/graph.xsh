##! Validation and ordering of a resource list. Pure: no host is consulted.

use infra.model

pure duplicates(resources: List[model.Resource]) -> List[Str] {
  var seen: Set[Str] = set.empty()
  var repeated = []
  for resource in resources {
    if resource.id in seen {
      if resource.id not in repeated {
        repeated += [resource.id]
      }
    } else {
      seen = seen.add(resource.id)
    }
  }

  repeated
}

pure unknown_dependencies(resources: List[model.Resource]) -> List[Str] {
  let known = resources |> map { |resource| resource.id } |> collect()
  let problems = collect {
    for resource in resources {
      for dependency in model.dependencies(resource) {
        if dependency == resource.id {
          yield f"resource {resource.id} needs itself"
        } else if dependency not in known {
          yield f"resource {resource.id} needs unknown resource {dependency}"
        }
      }
    }
  }

  problems
}

## Check identifiers and dependencies, then return the resources in an order
## where every resource follows what it needs. Among resources that are ready
## together, declaration order wins.
export pure order(resources: List[model.Resource]) -> Result[List[model.Resource], Error] {
  let problems = collect {
    for id in duplicates(resources) {
      yield f"duplicate resource id {id}"
    }

    yield @unknown_dependencies(resources)
  }
  guard problems.is_empty() else {
    fail problems.join("; ")
  }

  var placed: Set[Str] = set.empty()
  var remaining = resources
  let ordered: List[model.Resource] = collect {
    while ! remaining.is_empty() {
      let ready = remaining |> where { |resource|
        model.dependencies(resource) |> all { |dependency| dependency in placed }
      } |> first()
      guard let next = ready else {
        let stuck = remaining |> map { |resource| resource.id } |> collect()
        fail f"dependency cycle among resources: {stuck.join(", ")}"
      }

      yield next
      placed = placed.add(next.id)
      remaining = remaining |> where { |resource| resource.id != next.id } |> collect()
    }
  }

  Ok(ordered)
}

## Merge each host's ordered identifiers into one operation sequence. An
## operation is an identifier; every host that declares it takes part, and it
## follows everything declared before it on any host. Hosts that order two
## shared identifiers differently have no consistent sequence and are refused.
export pure merge_order(lists: List[List[Str]]) -> Result[List[Str], Error] {
  var seen = []
  for list in lists {
    for id in list {
      if id not in seen {
        seen += [id]
      }
    }
  }

  var placed: Set[Str] = set.empty()
  var remaining = seen
  let merged = collect {
    while ! remaining.is_empty() {
      let ready = remaining |> where { |id| ready_everywhere(id, lists, placed) } |> collect()
      guard ! ready.is_empty() else {
        fail f"hosts order these operations inconsistently: {remaining.join(", ")}"
      }

      yield ready[0]
      placed = placed.add(ready[0])
      remaining = remaining |> where { |id| id != ready[0] } |> collect()
    }
  }

  Ok(merged)
}

pure ready_everywhere(id: Str, lists: List[List[Str]], placed: Set[Str]) -> Bool {
  lists |> all { |list| earlier_placed(id, list, placed) }
}

pure earlier_placed(id: Str, list: List[Str], placed: Set[Str]) -> Bool {
  return true when id not in list

  for other in list {
    return true when other == id

    return false when other not in placed
  }

  true
}
