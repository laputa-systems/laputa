use xinfra.inventory
use xinfra.model
use xinfra.order
use xinfra.plan
use xinfra.validate

const PIN = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

proc host_inventory() -> inventory.Inventory {
  inventory.Inventory(
    groups: ["web"],
    hosts: [
      inventory.Host(
        name: "web-1",
        groups: ["web"],
        address: "192.0.2.10",
        port: 22,
        user: "xinfra",
        key: p"/keys/deploy",
        host_key: PIN,
      ),
    ],
  )
}

proc two_host_inventory() -> inventory.Inventory {
  inventory.Inventory(
    groups: ["web"],
    hosts: [
      inventory.Host(
        name: "web-1",
        groups: ["web"],
        address: "192.0.2.10",
        port: 22,
        user: "xinfra",
        key: p"/keys/deploy",
        host_key: PIN,
      ),
      inventory.Host(
        name: "web-2",
        groups: ["web"],
        address: "192.0.2.11",
        port: 22,
        user: "xinfra",
        key: p"/keys/deploy",
        host_key: PIN,
      ),
    ],
  )
}

proc digest(text: Str) -> Str {
  hash.sha256(bytes.from_text(text)).hex()
}

proc content_source(text: Str) -> validate.PreparedSource {
  validate.Content(validate.ContentSource(text: text, digest: digest(text)))
}

proc plan_one(
  resource: model.Resource,
  source: validate.PreparedSource?,
  observed: plan.Observed,
) -> plan.Action {
  var sources: Map[Str, validate.PreparedSource] = map.empty()
  if source != null {
    sources = sources.set(model.identity(resource), source)
  }

  let deployment = validate.Deployment(
    file: p"/repo/deploy.xsh",
    root: p"/repo",
    resources: [resource],
    sources: sources,
  )
  let observed_map: Map[Str, plan.Observed] = {[model.identity(resource)]: observed}
  let facts = plan.Facts(hosts: [plan.HostFacts(name: "web-1", observed: observed_map)])
  let actions = plan.plan(deployment, host_inventory(), facts)
  actions[0]
}

proc sorted(resources: List[model.Resource]) -> Result[List[model.Resource], Error] {
  match order.sort(resources) {
    Ok(value) => Ok(value),
    Err(problem) => Err(error.failure(problem.message)),
  }
}

proc directory_resource(id: Str, state: model.State = model.Present) -> model.Resource {
  model.Directory(model.DirectorySpec(id: id, path: p"/etc/app", state: state))
}

proc file_resource(id: Str, state: model.State = model.Present) -> model.Resource {
  model.File(
    model.FileSpec(
      id: id,
      path: p"/etc/app.conf",
      state: state,
      source: model.Content("managed\n"),
    ),
  )
}

test test_order_places_prerequisites_before_dependents { |ctx|
  let dependent = file_resource("dependent")
  let prerequisite = directory_resource("prerequisite")
  let independent = directory_resource("independent")
  let declaration = [
    model.File(
      model.FileSpec(
        id: "dependent",
        path: p"/etc/app.conf",
        source: model.Content("managed\n"),
        requires: ["prerequisite"],
      ),
    ),
    model.Directory(model.DirectorySpec(id: "independent", path: p"/etc/independent")),
    prerequisite,
  ]
  let ordered = sorted(declaration)?
  test.eq(ordered.len(), 3)?
  test.eq(model.identity(ordered[0]), "independent")?
  test.eq(model.identity(ordered[1]), "prerequisite")?
  test.eq(model.identity(ordered[2]), "dependent")?
}

test test_order_rejects_duplicates_unknown_and_cycles { |ctx|
  match order.sort([directory_resource("same"), directory_resource("same")]) {
    Ok(_) => test.fail("duplicate id unexpectedly sorted")?,
    Err(problem) => test.eq(problem.kind, "duplicate-id")?,
  }

  let unknown = model.Directory(
    model.DirectorySpec(id: "dependent", path: p"/etc/dependent", requires: ["absent"]),
  )
  match order.sort([unknown]) {
    Ok(_) => test.fail("unknown requirement unexpectedly sorted")?,
    Err(problem) => test.eq(problem.kind, "unknown-requirement")?,
  }

  let left = model.Directory(
    model.DirectorySpec(id: "left", path: p"/etc/left", requires: ["right"]),
  )
  let right = model.Directory(
    model.DirectorySpec(id: "right", path: p"/etc/right", requires: ["left"]),
  )
  match order.sort([left, right]) {
    Ok(_) => test.fail("cycle unexpectedly sorted")?,
    Err(problem) => test.eq(problem.kind, "dependency-cycle")?,
  }

  let self = model.Directory(
    model.DirectorySpec(id: "self", path: p"/etc/self", requires: ["self"]),
  )
  match order.sort([self]) {
    Ok(_) => test.fail("self cycle unexpectedly sorted")?,
    Err(problem) => test.eq(problem.kind, "dependency-cycle")?,
  }
}

test test_directory_comparison { |ctx|
  let present = directory_resource("app")
  let action = plan_one(present, null, plan.Absent)
  test.eq(action.prediction, plan.Changed)?
  test.eq(action.operation, plan.EnsureDirectory)?

  let matching = plan.Existing(plan.PathFacts(kind: "dir", mode: 0o755, owner: "root", group: "root"))
  test.eq(plan_one(present, null, matching).prediction, plan.Unchanged)?

  let drifted = plan.Existing(plan.PathFacts(kind: "dir", mode: 0o700, owner: "root", group: "root"))
  test.eq(plan_one(present, null, drifted).prediction, plan.Changed)?

  let conflict = plan.Existing(plan.PathFacts(kind: "file", mode: 0o644))
  test.eq(plan_one(present, null, conflict).prediction, plan.Blocked)?

  let absent = directory_resource("app", model.Absent)
  test.eq(plan_one(absent, null, plan.Absent).prediction, plan.Unchanged)?
  test.eq(plan_one(absent, null, plan.Existing(plan.PathFacts(kind: "dir", mode: 0o755, empty: true))).prediction, plan.Changed)?
  test.eq(plan_one(absent, null, plan.Existing(plan.PathFacts(kind: "dir", mode: 0o755, empty: false))).prediction, plan.Blocked)?
  test.eq(plan_one(absent, null, conflict).prediction, plan.Blocked)?
}

test test_file_comparison { |ctx|
  let source = content_source("managed\n")
  let present = file_resource("app-conf")
  let matching = plan.Existing(
    plan.PathFacts(kind: "file", mode: 0o644, digest: digest("managed\n")),
  )
  let drift = plan.Existing(plan.PathFacts(kind: "file", mode: 0o644, digest: digest("other\n")))
  let mode_drift = plan.Existing(
    plan.PathFacts(kind: "file", mode: 0o600, digest: digest("managed\n")),
  )

  test.eq(plan_one(present, source, plan.Absent).prediction, plan.Changed)?
  test.eq(plan_one(present, source, matching).prediction, plan.Unchanged)?
  test.eq(plan_one(present, source, drift).prediction, plan.Changed)?
  test.eq(plan_one(present, source, mode_drift).prediction, plan.Changed)?
  test.eq(plan_one(present, source, plan.Existing(plan.PathFacts(kind: "dir", mode: 0o755))).prediction, plan.Blocked)?

  let absent = file_resource("app-conf", model.Absent)
  test.eq(plan_one(absent, null, plan.Absent).prediction, plan.Unchanged)?
  test.eq(plan_one(absent, null, matching).prediction, plan.Changed)?
  test.eq(plan_one(absent, null, plan.Unknown).prediction, plan.Undetermined)?
}

test test_secret_file_comparison_is_unknown_when_present { |ctx|
  let secret = model.File(
    model.FileSpec(id: "token", path: p"/etc/token", source: model.Secret(model.FromEnv("TOKEN"))),
  )
  let source = validate.Secret(model.FromEnv("TOKEN"))
  test.eq(plan_one(secret, source, plan.Absent).prediction, plan.Changed)?
  test.eq(
    plan_one(
      secret,
      source,
      plan.Existing(plan.PathFacts(kind: "file", mode: 0o600, digest: digest("old"))),
    ).prediction,
    plan.Undetermined,
  )?
}

test test_symlink_comparison { |ctx|
  let link = model.Symlink(
    model.SymlinkSpec(id: "link", path: p"/etc/link", target: p"/etc/app.conf"),
  )
  let matching = plan.Existing(plan.PathFacts(kind: "symlink", mode: 0o777, target: p"/etc/app.conf"))
  let other = plan.Existing(plan.PathFacts(kind: "symlink", mode: 0o777, target: p"/etc/other"))
  test.eq(plan_one(link, null, plan.Absent).prediction, plan.Changed)?
  test.eq(plan_one(link, null, matching).prediction, plan.Unchanged)?
  test.eq(plan_one(link, null, other).prediction, plan.Blocked)?
  test.eq(plan_one(link, null, plan.Existing(plan.PathFacts(kind: "file", mode: 0o644))).prediction, plan.Blocked)?

  let replace = model.Symlink(
    model.SymlinkSpec(id: "link", path: p"/etc/link", target: p"/etc/app.conf", replace: true),
  )
  test.eq(plan_one(replace, null, other).prediction, plan.Changed)?
  test.eq(plan_one(replace, null, plan.Existing(plan.PathFacts(kind: "file", mode: 0o644))).prediction, plan.Changed)?

  let absent = model.Symlink(
    model.SymlinkSpec(id: "link", path: p"/etc/link", target: p"/etc/app.conf", state: model.Absent),
  )
  test.eq(plan_one(absent, null, plan.Absent).prediction, plan.Unchanged)?
  test.eq(plan_one(absent, null, matching).prediction, plan.Changed)?
  test.eq(plan_one(absent, null, plan.Existing(plan.PathFacts(kind: "file", mode: 0o644))).prediction, plan.Blocked)?
}

test test_package_comparison { |ctx|
  let present = model.Package(model.PackageSpec(id: "nginx", name: "nginx"))
  test.eq(plan_one(present, null, plan.Absent).prediction, plan.Changed)?
  test.eq(plan_one(present, null, plan.Installed(plan.PackageFacts(version: "1.26.2"))).prediction, plan.Unchanged)?

  let constrained = model.Package(
    model.PackageSpec(id: "nginx", name: "nginx", constraint: ">=1.26"),
  )
  test.eq(
    plan_one(constrained, null, plan.Installed(plan.PackageFacts(version: "1.26.2", satisfies: true))).prediction,
    plan.Unchanged,
  )?
  test.eq(
    plan_one(constrained, null, plan.Installed(plan.PackageFacts(version: "1.24", satisfies: false))).prediction,
    plan.Changed,
  )?
  test.eq(
    plan_one(constrained, null, plan.Installed(plan.PackageFacts(version: null, satisfies: null))).prediction,
    plan.Undetermined,
  )?

  let absent = model.Package(model.PackageSpec(id: "nginx", name: "nginx", state: model.Absent))
  test.eq(plan_one(absent, null, plan.Installed(plan.PackageFacts(version: "1.26.2"))).prediction, plan.Changed)?
  test.eq(plan_one(absent, null, plan.Absent).prediction, plan.Unchanged)?
}

test test_user_comparison { |ctx|
  let present = model.UserResource(
    model.UserSpec(
      id: "webapp",
      name: "webapp",
      uid: 1001,
      gid: 1001,
      home: p"/var/www",
      shell: p"/sbin/nologin",
      groups: ["web"],
    ),
  )
  let matching = plan.Account(
    plan.UserFacts(uid: 1001, gid: 1001, groups: ["web"], home: p"/var/www", shell: p"/sbin/nologin"),
  )
  let home_drift = plan.Account(
    plan.UserFacts(uid: 1001, gid: 1001, groups: ["web"], home: p"/home/webapp", shell: p"/sbin/nologin"),
  )
  test.eq(plan_one(present, null, plan.Absent).prediction, plan.Changed)?
  test.eq(plan_one(present, null, matching).prediction, plan.Unchanged)?
  test.eq(plan_one(present, null, home_drift).prediction, plan.Blocked)?

  let update_home = model.UserResource(
    model.UserSpec(id: "webapp", name: "webapp", home: p"/var/www", update: true),
  )
  let drift_with_declared_home = plan.Account(
    plan.UserFacts(uid: 1001, gid: 1001, home: p"/home/webapp"),
  )
  test.eq(plan_one(update_home, null, drift_with_declared_home).prediction, plan.Changed)?

  let uid_drift = plan.Account(plan.UserFacts(uid: 2000, gid: 1001))
  test.eq(plan_one(present, null, uid_drift).prediction, plan.Blocked)?

  let absent = model.UserResource(
    model.UserSpec(id: "webapp", name: "webapp", state: model.Absent),
  )
  test.eq(plan_one(absent, null, matching).prediction, plan.Changed)?
  test.eq(plan_one(absent, null, plan.Absent).prediction, plan.Unchanged)?
}

test test_group_comparison { |ctx|
  let present = model.GroupResource(model.GroupSpec(id: "web", name: "web", gid: 1001))
  test.eq(plan_one(present, null, plan.Absent).prediction, plan.Changed)?
  test.eq(plan_one(present, null, plan.Role(plan.GroupFacts(gid: 1001))).prediction, plan.Unchanged)?
  test.eq(plan_one(present, null, plan.Role(plan.GroupFacts(gid: 2000))).prediction, plan.Blocked)?
}

test test_command_comparison { |ctx|
  let always = model.CommandResource(
    model.CommandSpec(id: "run", argv: ["true"], always_run: true),
  )
  test.eq(plan_one(always, null, plan.Invocation(plan.CommandFacts())).prediction, plan.Changed)?

  let creates = model.CommandResource(
    model.CommandSpec(id: "run", argv: ["true"], creates: p"/tmp/done"),
  )
  test.eq(
    plan_one(creates, null, plan.Invocation(plan.CommandFacts(creates_present: true))).prediction,
    plan.Unchanged,
  )?
  test.eq(
    plan_one(creates, null, plan.Invocation(plan.CommandFacts(creates_present: false))).prediction,
    plan.Changed,
  )?
  test.eq(
    plan_one(creates, null, plan.Invocation(plan.CommandFacts(creates_present: null))).prediction,
    plan.Undetermined,
  )?

  let guarded = model.CommandResource(
    model.CommandSpec(
      id: "run",
      argv: ["true"],
      creates: p"/tmp/done",
      unless_argv: ["test", "-e", "/tmp/other"],
    ),
  )
  test.eq(
    plan_one(
      guarded,
      null,
      plan.Invocation(plan.CommandFacts(creates_present: true, unless_satisfied: null)),
    ).prediction,
    plan.Unchanged,
  )?
  test.eq(
    plan_one(
      guarded,
      null,
      plan.Invocation(plan.CommandFacts(creates_present: false, unless_satisfied: true)),
    ).prediction,
    plan.Unchanged,
  )?
}

test test_service_comparison { |ctx|
  let started = model.ServiceResource(
    model.ServiceSpec(id: "nginx", name: "nginx", state: model.Started, enabled: true),
  )
  test.eq(
    plan_one(started, null, plan.Running(plan.ServiceFacts(started: true, enabled: true))).prediction,
    plan.Unchanged,
  )?
  test.eq(
    plan_one(started, null, plan.Running(plan.ServiceFacts(started: false, enabled: false))).prediction,
    plan.Changed,
  )?
  test.eq(
    plan_one(started, null, plan.Running(plan.ServiceFacts(started: true, enabled: false))).prediction,
    plan.Changed,
  )?
  test.eq(
    plan_one(started, null, plan.Running(plan.ServiceFacts(started: true, enabled: null))).prediction,
    plan.Undetermined,
  )?

  let stopped = model.ServiceResource(
    model.ServiceSpec(id: "nginx", name: "nginx", state: model.Stopped),
  )
  test.eq(plan_one(stopped, null, plan.Running(plan.ServiceFacts(started: true))).prediction, plan.Changed)?
  test.eq(plan_one(stopped, null, plan.Running(plan.ServiceFacts(started: false))).prediction, plan.Unchanged)?
}

test test_dependencies_block_dependents { |ctx|
  let prerequisite = directory_resource("prerequisite")
  let dependent = model.File(
    model.FileSpec(
      id: "dependent",
      path: p"/etc/dependent",
      source: model.Content("x"),
      requires: ["prerequisite"],
    ),
  )
  let blocked = plan.Existing(plan.PathFacts(kind: "file", mode: 0o644))
  let deployment = validate.Deployment(
    file: p"/repo/deploy.xsh",
    root: p"/repo",
    resources: sorted([dependent, prerequisite])?,
    sources: {"dependent": content_source("x")},
  )
  let observed_map: Map[Str, plan.Observed] = {
    "prerequisite": blocked,
    "dependent": plan.Absent,
  }
  let facts = plan.Facts(hosts: [plan.HostFacts(name: "web-1", observed: observed_map)])
  let actions = plan.plan(deployment, host_inventory(), facts)
  test.eq(actions.len(), 2)?
  test.eq(actions[0].id, "prerequisite")?
  test.eq(actions[0].prediction, plan.Blocked)?
  test.eq(actions[1].id, "dependent")?
  test.eq(actions[1].prediction, plan.Blocked)?
  test.ok((actions[1].cause ?? "").find("prerequisite") != null)?
}

test test_prerequisite_must_be_selected_for_the_host { |ctx|
  let prerequisite = model.Directory(
    model.DirectorySpec(id: "prerequisite", path: p"/etc/prerequisite", hosts: ["db"]),
  )
  let dependent = model.File(
    model.FileSpec(
      id: "dependent",
      path: p"/etc/dependent",
      source: model.Content("x"),
      requires: ["prerequisite"],
    ),
  )
  let deployment = validate.Deployment(
    file: p"/repo/deploy.xsh",
    root: p"/repo",
    resources: sorted([dependent, prerequisite])?,
    sources: {"dependent": content_source("x")},
  )
  let facts = plan.Facts(
    hosts: [
      plan.HostFacts(
        name: "web-1",
        observed: {
          "dependent": plan.Absent,
          "prerequisite": plan.Absent,
        },
      ),
    ],
  )
  let actions = plan.plan(deployment, host_inventory(), facts)
  test.eq(actions.len(), 1)?
  test.eq(actions[0].id, "dependent")?
  test.eq(actions[0].prediction, plan.Blocked)?
}

test test_host_selection_limits_actions { |ctx|
  let webonly = model.Directory(
    model.DirectorySpec(id: "webonly", path: p"/etc/webonly", hosts: ["web"]),
  )
  let dbs = model.Directory(
    model.DirectorySpec(id: "dbs", path: p"/etc/dbs", hosts: ["db"]),
  )
  let deployment = validate.Deployment(
    file: p"/repo/deploy.xsh",
    root: p"/repo",
    resources: [dbs, webonly],
    sources: map.empty(),
  )
  let facts = plan.empty_facts(["web-1", "db-1"])
  let actions = plan.plan(deployment, host_inventory(), facts)
  test.eq(actions.len(), 1)?
  test.eq(actions[0].id, "webonly")?
  test.eq(actions[0].host, "web-1")?
}

test test_plan_is_ordered_by_resource_then_host { |ctx|
  let first = directory_resource("first")
  let second = directory_resource("second")
  let deployment = validate.Deployment(
    file: p"/repo/deploy.xsh",
    root: p"/repo",
    resources: [first, second],
    sources: map.empty(),
  )
  let facts = plan.empty_facts(["web-1", "web-2"])
  let actions = plan.plan(deployment, two_host_inventory(), facts)
  test.eq(actions.len(), 4)?
  test.eq(actions[0].id, "first")?
  test.eq(actions[0].host, "web-1")?
  test.eq(actions[1].id, "first")?
  test.eq(actions[1].host, "web-2")?
  test.eq(actions[2].id, "second")?
  test.eq(actions[3].id, "second")?
}

test test_verify_requires_the_intended_state { |ctx|
  let resource = directory_resource("app")
  let matching = plan.Existing(plan.PathFacts(kind: "dir", mode: 0o755))
  let drifted = plan.Existing(plan.PathFacts(kind: "dir", mode: 0o700))
  test.ok(plan.verify(resource, null, matching).ok)?
  test.ok(! plan.verify(resource, null, drifted).ok)?
  let drift = plan.verify(resource, null, drifted)
  test.ok((drift.cause ?? "").is_empty() == false)?
}
