##! Remote fact matrix against the disposable fixtures.

use xinfra.cache as cache
use xinfra.facts as facts
use xinfra.parse as parse
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

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the fact matrix.
export proc execute() [fs, process, env, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?

  with session = connect(a)? {
    let _ = transport.exec(session, ["doas", "-n", "rc-service", "crond", "stop"])?
    let _ = transport.exec(session, ["doas", "-n", "rc-update", "del", "crond", "default"])?

    let file = facts.file_fact(session, "/etc/alpine-release")?
    require(file.kind == "present", "present file was not present")?
    require(facts.field(file.fields, "size") != "0", "present file had no size")?
    print test_case("file present")

    let absent = facts.file_fact(session, "/etc/xinfra-no-such-file")?
    require(absent.kind == "absent", "missing file was not absent")?
    print test_case("file absent")

    let denied = facts.file_fact(session, "/root/xinfra-facts")?
    require(denied.kind == "unknown", "unreadable file was not unknown")?
    require(denied.kind != "absent", "unreadable file became absent")?
    print test_case("file denied is unknown")

    require(parse.file_stat("garbage").kind == "malformed", "malformed stat was accepted")?
    print test_case("malformed fact")

    let user_fact = facts.user_fact(session, "xinfra")?
    require(user_fact.kind == "present", "fixture user was absent")?
    require(facts.field(user_fact.fields, "uid") != "", "fixture user had no uid")?
    print test_case("user present")

    let no_user = facts.user_fact(session, "xinfra-no-such-user")?
    require(no_user.kind == "absent", "missing user was not absent")?
    print test_case("user absent")

    let group_fact = facts.group_fact(session, "xinfra")?
    require(group_fact.kind == "present", "fixture group was absent")?
    print test_case("group present")

    let no_group = facts.group_fact(session, "xinfra-no-such-group")?
    require(no_group.kind == "absent", "missing group was not absent")?
    print test_case("group absent")

    let package = facts.package_fact(session, "busybox")?
    require(package.kind == "present", "busybox was absent")?
    require(facts.field(package.fields, "version") != "", "busybox had no version")?
    print test_case("package present and version")

    let no_package = facts.package_fact(session, "xinfra-no-such-package")?
    require(no_package.kind == "absent", "missing package was not absent")?
    print test_case("package absent")

    let service = facts.service_fact(session, "sshd")?
    require(service.kind == "present", "sshd service was not present")?
    require(facts.field(service.fields, "status") == "started", "sshd was not started")?
    require(facts.field(service.fields, "enabled") == "yes", "sshd was not enabled")?
    print test_case("service started and enabled")

    let stopped = facts.service_fact(session, "crond")?
    require(facts.field(stopped.fields, "status") == "stopped", "crond was not stopped")?
    print test_case("service stopped")

    let before = facts.file_fact(session, "/etc/alpine-release")?
    let _ = facts.batch(session, [
      {kind: "file", name: "/etc/alpine-release"},
      {kind: "user", name: "xinfra"},
      {kind: "package", name: "busybox"},
    ])?
    let after = facts.file_fact(session, "/etc/alpine-release")?
    require(facts.field(before.fields, "mtime") == facts.field(after.fields, "mtime"), "fact read mutated the file")?
    print test_case("batch queries do not mutate")

    var facts_cache = cache.empty()
    let first = facts.read_cached(facts_cache, session, a.host, "user", {kind: "file", name: "/etc/alpine-release"})?
    facts_cache = first.cache
    require(!first.hit, "first cache read was a hit")?

    let second = facts.read_cached(facts_cache, session, a.host, "user", {kind: "file", name: "/etc/alpine-release"})?
    facts_cache = second.cache
    require(second.hit, "second cache read missed")?
    require(second.fact == first.fact, "cached fact changed")?

    let other_host = facts.read_cached(facts_cache, session, "xinfra-other", "user", {kind: "file", name: "/etc/alpine-release"})?
    require(!other_host.hit, "cache ignored host scope")?
    facts_cache = other_host.cache

    let other_privilege = facts.read_cached(facts_cache, session, a.host, "root", {kind: "file", name: "/etc/alpine-release"})?
    require(!other_privilege.hit, "cache ignored privilege scope")?
    facts_cache = other_privilege.cache

    let generation = facts_cache.generation
    facts_cache = cache.invalidate(facts_cache)
    require(facts_cache.generation == generation + 1, "invalidation did not advance generation")?
    let after_invalidate = facts.read_cached(facts_cache, session, a.host, "user", {kind: "file", name: "/etc/alpine-release"})?
    require(!after_invalidate.hit, "invalidated cache was a hit")?
    print test_case("cache scope and invalidation")
  }

  Ok()
}
