##! Remote directory and symlink matrix.

use xinfra.host as host
use xinfra.model as model
use xinfra.plan as plan
use xinfra.remote as remote
use xinfra.resources.dir as dir
use xinfra.resources.symlink as symlink
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

proc inspect(session: transport.Session, target: Path) -> Result[host.Inspection, Str] {
  match remote.inspect_path(session, target) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

proc run_command(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Str] {
  transport.exec(session, argv)
}

pure status_name(status: host.ApplyStatus) -> Str {
  if status == host.Changed {
    return "changed"
  }
  if status == host.Unchanged {
    return "unchanged"
  }
  if status == host.Failed {
    return "failed"
  }
  if status == host.Partial {
    return "partial"
  }
  if status == host.Blocked {
    return "blocked"
  }
  if status == host.Unknown {
    return "unknown"
  }
  "other"
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the directory and symlink matrix.
export proc check_dirs() [fs, process, env, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?
  let base = p"/home/xinfra/xinfra-r3a"

  with session = connect(a)? {
    let _ = run_command(session, ["rm", "-rf", base.display()])?
    let _ = run_command(session, ["mkdir", "-p", base.display()])?

    let managed = fp"{base}/managed"
    let spec = model.DirectorySpec(id: "managed", path: managed, mode: 0o750)
    let first = dir.apply_remote(session, a.host, spec)
    require(first.status == host.Changed and first.verified, "first directory apply was not changed")?
    let second = dir.apply_remote(session, a.host, spec)
    require(second.status == host.Unchanged and second.verified, "second directory apply was not unchanged")?
    print test_case("directory first and second apply")

    let _ = run_command(session, ["chmod", "700", managed.display()])?
    let drifted = dir.apply_remote(session, a.host, spec)
    require(drifted.status == host.Changed and drifted.verified, "directory drift was not repaired")?
    match inspect(session, managed)? {
      host.Found(stat) => require(stat.mode == 0o750, "directory mode was not repaired")?,
      host.Missing => return Err("repaired directory disappeared"),
    }
    print test_case("directory drift repair")

    let before = inspect(session, managed)?
    let observed = host.observed(before)
    let assessment = plan.assess(model.Directory(spec), null, observed)
    require(assessment.prediction == plan.Unchanged, "plan saw drift after repair")?
    let after = inspect(session, managed)?
    require(before == after, "plan mutated the directory")?
    print test_case("plan performs no write")

    let child_dir = fp"{managed}/child"
    let child_spec = model.DirectorySpec(id: "child", path: child_dir)
    let child_applied = dir.apply_remote(session, a.host, child_spec)
    require(child_applied.status == host.Changed, "child directory was not created")?
    let absent_parent = model.DirectorySpec(id: "managed", path: managed, state: model.Absent)
    let blocked = dir.apply_remote(session, a.host, absent_parent)
    require(blocked.status == host.Failed or blocked.status == host.Partial or blocked.status == host.Blocked, "non-empty directory removal was not refused")?
    match inspect(session, child_dir)? {
      host.Found(_) => {}
      host.Missing => return Err("one-level removal deleted the child"),
    }
    print test_case("one-level directory absence")

    let file_path = fp"{base}/plain-file"
    let _ = run_command(session, ["sh", "-c", f"printf x > {file_path.display()}"])?
    let conflict = dir.apply_remote(session, a.host, model.DirectorySpec(id: "conflict", path: file_path))
    require(conflict.status == host.Blocked, "file/directory conflict was not blocked")?
    print test_case("directory type conflict")

    let target = fp"{base}/target"
    let _ = run_command(session, ["mkdir", "-p", target.display()])?
    let link = fp"{base}/link"
    let link_spec = model.SymlinkSpec(id: "link", path: link, target: target)
    let link_first = symlink.apply_remote(session, a.host, link_spec)
    require(
      link_first.status == host.Changed and link_first.verified,
      f"symlink was not created: {status_name(link_first.status)} {link_first.cause ?? ""}",
    )?
    let link_second = symlink.apply_remote(session, a.host, link_spec)
    require(link_second.status == host.Unchanged, "second symlink apply was not unchanged")?
    print test_case("symlink first and second apply")

    let nested = fp"{base}/nested"
    let _ = run_command(session, ["mkdir", "-p", nested.display()])?
    let relative_link = fp"{nested}/current"
    let relative_spec = model.SymlinkSpec(id: "relative", path: relative_link, target: p"../target")
    let relative = symlink.apply_remote(session, a.host, relative_spec)
    require(relative.status == host.Changed and relative.verified, "relative symlink was not created")?
    match inspect(session, relative_link)? {
      host.Found(stat) => require((stat.target ?? p"") == p"../target", "relative target changed")?,
      host.Missing => return Err("relative symlink disappeared"),
    }
    let dash_link = fp"{nested}/dash"
    let dash_spec = model.SymlinkSpec(id: "dash", path: dash_link, target: p"-dash")
    let dash = symlink.apply_remote(session, a.host, dash_spec)
    require(dash.status == host.Changed and dash.verified, "dash symlink was not created")?
    match inspect(session, dash_link)? {
      host.Found(stat) => require((stat.target ?? p"") == p"-dash", "dash target changed")?,
      host.Missing => return Err("dash symlink disappeared"),
    }
    print test_case("relative and dash symlink targets")

    let _ = run_command(session, ["rm", "-f", link.display()])?
    let _ = run_command(session, ["sh", "-c", f"printf x > {link.display()}"])?
    let no_replace = symlink.apply_remote(session, a.host, link_spec)
    require(no_replace.status == host.Blocked, "replace=false replaced a file")?
    let replace_spec = model.SymlinkSpec(id: "link", path: link, target: target, replace: true)
    let replaced = symlink.apply_remote(session, a.host, replace_spec)
    require(replaced.status == host.Changed and replaced.verified, "replace=true did not replace the file")?
    print test_case("symlink replacement policy")

    let hostile = fp"{base}/a b'$(echo nope)'"
    let hostile_spec = model.DirectorySpec(id: "hostile", path: hostile, mode: 0o755)
    let hostile_result = dir.apply_remote(session, a.host, hostile_spec)
    require(hostile_result.status == host.Changed, "hostile path was not created")?
    match inspect(session, hostile)? {
      host.Found(stat) => require(stat.kind == "dir", "hostile path is not a directory")?,
      host.Missing => return Err("hostile path disappeared"),
    }
    print test_case("hostile path quoting")

    let escape = fp"{base}/../xinfra-r3a-escape"
    let traversal = dir.apply_remote(session, a.host, model.DirectorySpec(id: "escape", path: escape))
    require(traversal.status == host.Failed, "traversal path was not rejected")?
    let outside = run_command(session, ["test", "-e", escape.display()])?
    require(outside.exit_code != 0, "traversal path wrote outside the base")?
    print test_case("no traversal")

    let _ = run_command(session, ["rm", "-rf", base.display()])?
  }

  Ok()
}
