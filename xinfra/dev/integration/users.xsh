##! Remote user and group matrix.

use xinfra.host as host
use xinfra.model as model
use xinfra.plan as plan
use xinfra.resources.group as group_resource
use xinfra.resources.user as user_resource
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

proc user_fact(session: transport.Session, name: Str) -> Result[plan.Observed, Str] {
  match user_resource.fact(session, name) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

proc group_fact(session: transport.Session, name: Str) -> Result[plan.Observed, Str] {
  match group_resource.fact(session, name) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

proc apply_user(session: transport.Session, host_name: Str, spec: model.UserSpec, elevate: List[Str]) -> Result[host.ApplyResult, Str] {
  match user_resource.apply_remote(session, host_name, spec, elevate) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

proc apply_group(session: transport.Session, host_name: Str, spec: model.GroupSpec, elevate: List[Str]) -> Result[host.ApplyResult, Str] {
  match group_resource.apply_remote(session, host_name, spec, elevate) {
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

## Executes the user and group matrix.
export proc check_users() [fs, process, env, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?

  with session = connect(a)? {
    let elevate = ["sudo", "-n"]
    let test_group = "xinfra-r4b"
    let test_user = "xinfra-r4b-user"
    let failed_user = "xinfra-r4b-fail"
    let home = p"/home/xinfra-r4b-user"

    let _ = execute(session, [@elevate, "deluser", test_user])?
    let _ = execute(session, [@elevate, "deluser", failed_user])?
    let _ = execute(session, [@elevate, "delgroup", test_group])?
    let _ = execute(session, [@elevate, "rm", "-rf", home.display()])?

    let group_spec = model.GroupSpec(id: "group", name: test_group, gid: 1500)
    let group_first = apply_group(session, a.host, group_spec, elevate)?
    require(group_first.status == host.Changed and group_first.verified, f"group create failed: {status_name(group_first.status)}")?
    let group_second = apply_group(session, a.host, group_spec, elevate)?
    require(group_second.status == host.Unchanged, "second group apply was not unchanged")?
    match group_fact(session, test_group)? {
      plan.Role(facts) => require(facts.gid == 1500, "group gid was not applied")?,
      _ => return Err("created group is missing"),
    }
    print test_case("group present and unchanged")

    let user_spec = model.UserSpec(
      id: "user",
      name: test_user,
      uid: 1500,
      gid: 1500,
      home: home,
      shell: p"/bin/sh",
      groups: [test_group],
      create_home: true,
    )
    let user_first = apply_user(session, a.host, user_spec, elevate)?
    require(user_first.status == host.Changed and user_first.verified, f"user create failed: {status_name(user_first.status)} {user_first.cause ?? ""}")?
    let user_second = apply_user(session, a.host, user_spec, elevate)?
    require(user_second.status == host.Unchanged, "second user apply was not unchanged")?
    match user_fact(session, test_user)? {
      plan.Account(facts) => {
        require(facts.uid == 1500 and facts.gid == 1500, "user ids were not applied")?
        require(facts.home == home, "user home was not applied")?
        require(facts.shell == p"/bin/sh", "user shell was not applied")?
        require(test_group in facts.groups, "user group was not applied")?
      }
      _ => return Err("created user is missing"),
    }
    print test_case("user present, ids, home, shell, groups")

    let conflict = model.UserSpec(id: "user", name: test_user, shell: p"/bin/ash")
    let blocked = apply_user(session, a.host, conflict, elevate)?
    require(blocked.status == host.Blocked, "existing shell conflict was not blocked")?
    let changed = model.UserSpec(id: "user", name: test_user, shell: p"/bin/ash", update: true)
    let updated = apply_user(session, a.host, changed, elevate)?
    require(updated.status == host.Changed and updated.verified, "explicit shell update failed")?
    print test_case("existing conflict is conservative unless update")

    let uid_change = model.UserSpec(id: "user", name: test_user, uid: 1501)
    let rejected = apply_user(session, a.host, uid_change, elevate)?
    require(rejected.status == host.Blocked, "uid change was not rejected")?
    print test_case("uid and gid changes are rejected")

    let _ = execute(session, [@elevate, "sh", "-c", f"printf keep > {home.display()}/keep"])?
    let absent = model.UserSpec(id: "user", name: test_user, state: model.Absent)
    let kept = apply_user(session, a.host, absent, elevate)?
    require(kept.status == host.Blocked, "user with non-empty home was removed")?
    let kept_file = execute(session, ["test", "-f", f"{home.display()}/keep"])?
    require(kept_file.exit_code == 0, "non-empty home was deleted")?
    match user_fact(session, test_user)? {
      plan.Account(_) => {}
      _ => return Err("blocked removal deleted the user"),
    }
    print test_case("absent preserves non-empty home")

    let denied = model.UserSpec(id: "denied", name: failed_user, create_home: true)
    let failed = apply_user(session, a.host, denied, [])?
    require(failed.status == host.Failed or failed.status == host.Partial, "failed escalation reported success")?
    match user_fact(session, failed_user)? {
      plan.Absent => {}
      _ => return Err("failed escalation created the user"),
    }
    print test_case("failed escalation is not success")

    let _ = execute(session, [@elevate, "rm", "-rf", home.display()])?
    let removed_user = apply_user(session, a.host, absent, elevate)?
    require(removed_user.status == host.Changed and removed_user.verified, "user removal failed")?
    let removed_group = apply_group(session, a.host, model.GroupSpec(id: "group", name: test_group, state: model.Absent), elevate)?
    require(removed_group.status == host.Changed and removed_group.verified, "group removal failed")?
    print test_case("user and group removal")
  }

  Ok()
}
