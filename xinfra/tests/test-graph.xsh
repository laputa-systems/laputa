use infra.declare
use infra.graph
use infra.model

pure dir(id: Str, needs: List[Str] = []) -> model.Resource {
  declare.directory(id:, at: f"/srv/{id}", needs:) ?? model.Resource(id:, needs:, spec: model.PackageIndex(model.PackageIndexSpec(note: "")))
}

pure ids(resources: List[model.Resource]) -> List[Str] {
  resources |> map { |resource| resource.id }
}

pure refused(result: Result[List[model.Resource], Error], needle: Str) -> Bool {
  match result {
    Ok(_) => false
    Err(error) => needle in error.message
  }
}

test declaration_order_is_kept_when_dependencies_allow {
  let ordered = graph.order([dir("a"), dir("b"), dir("c")])?
  assert ids(ordered) == ["a", "b", "c"]
}

test a_dependency_moves_ahead_of_its_dependent {
  let ordered = graph.order([dir("a", needs: ["c"]), dir("b"), dir("c")])?
  assert ids(ordered) == ["b", "c", "a"]
}

test ordering_is_stable_among_independent_resources {
  let ordered = graph.order([dir("d", needs: ["a"]), dir("c"), dir("b", needs: ["a"]), dir("a")])?
  assert ids(ordered) == ["c", "a", "d", "b"]
}

test duplicate_identifiers_are_all_reported {
  let result = graph.order([dir("a"), dir("b"), dir("a"), dir("b")])
  assert refused(result, "duplicate resource id a")
  assert refused(result, "duplicate resource id b")
}

test an_unknown_dependency_names_both_resources {
  let result = graph.order([dir("a", needs: ["ghost"])])
  assert refused(result, "a needs unknown resource ghost")
}

test a_resource_cannot_need_itself {
  assert refused(graph.order([dir("a", needs: ["a"])]), "a needs itself")
}

test a_cycle_names_the_resources_on_it {
  let result = graph.order([dir("a", needs: ["b"]), dir("b", needs: ["c"]), dir("c", needs: ["a"]), dir("d")])
  assert refused(result, "dependency cycle")
  assert refused(result, "a, b, c")
}

test service_triggers_are_dependencies {
  let service = declare.service(id: "svc", name: "sshd", reload_on: ["conf"])?
  let ordered = graph.order([service, dir("conf")])?
  assert ids(ordered) == ["conf", "svc"]
}

test an_empty_list_orders_to_an_empty_list {
  let none: List[model.Resource] = []
  assert graph.order(none)? == none
}

test hosts_that_declare_the_same_operations_share_one_sequence {
  let order = graph.merge_order([["a", "b", "c"], ["a", "b", "c"]])?
  assert order == ["a", "b", "c"]
}

test an_operation_only_some_hosts_declare_slots_into_the_shared_sequence {
  let order = graph.merge_order([["a", "c"], ["a", "b", "c"], ["a", "d"]])?
  assert order == ["a", "b", "c", "d"]
}

test hosts_that_order_shared_operations_differently_are_refused {
  let result = graph.merge_order([["a", "b"], ["b", "a"]])
  match result {
    Ok(_) => assert false, "inconsistent orders were merged"
    Err(error) => assert "order" in error.message
  }
}

pure position(list: List[Str], id: Str) -> Int {
  for index in range(list.len()) {
    if list[index] == id {
      return index
    }
  }

  -1
}

test the_merged_sequence_respects_every_hosts_order_for_many_generated_inputs {
  let universe = ["a", "b", "c", "d", "e", "f", "g"]
  var state = 7
  for round in range(60) {
    var lists: List[List[Str]] = []
    for host in range(3) {
      var picked: List[Str] = []
      for id in universe {
        state = (state * 1103515245 + 12345) % 2147483648
        if state / 65536 % 3 != 0 {
          picked += [id]
        }
      }

      lists += [picked]
    }

    let merged = graph.merge_order(lists)?
    for list in lists {
      for index in range(list.len() - 1) {
        assert position(merged, list[index]) < position(merged, list[index + 1]), f"round {round}"
      }
    }
  }
}
