##! Failed privilege escalation remains an observed failure.

use xinfra.host as host
use xinfra.model as model
use xinfra.plan as plan
use xinfra.remote as remote
use xinfra.resources.dir as dir
use xinfra.resources.file as file
use xinfra.resources.package as package
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

pure content(text: Str) -> validate.PreparedSource {
  validate.Content(validate.ContentSource(text: text, digest: hash.sha256(bytes.from_text(text)).hex()))
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

pure failed_or_partial(status: host.ApplyStatus) -> Bool {
  status == host.Failed or status == host.Partial
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Execute the failed privilege scenario.
export proc check_privilege() [fs, process, env, error, io] -> Result[Unit, Error] {
  let a = fixture("A")?
  let denied_user = "xinfra-q2-denied"
  let denied_path = p"/etc/xinfra-q2-denied"
  let denied_dir = p"/etc/xinfra-q2-denied-dir"

  with session = connect(a)? {
    let elevate = ["doas", "-n"]
    let _ = execute(session, [@elevate, "userdel", denied_user])?
    let _ = execute(session, [@elevate, "rm", "-rf", denied_path.display(), denied_dir.display()])?
    let _ = execute(session, [@elevate, "apk", "del", "tree"])?

    let user_spec = model.UserSpec(id: "denied", name: denied_user, system: true)
    let user_result = user_resource.apply_remote(session, a.host, user_spec, [])?
    require(failed_or_partial(user_result.status), f"failed user escalation reported {status_name(user_result.status)}")?
    match user_resource.fact(session, denied_user)? {
      plan.Absent => {}
      _ => return Err(error.failure("failed user escalation created an account")),
    }
    print test_case("user escalation failure is observed")

    let file_spec = model.FileSpec(id: "denied-file", path: denied_path, mode: 0o600)
    let file_result = file.apply_remote(session, a.host, file_spec, content("denied\n"))
    require(failed_or_partial(file_result.status), f"failed file escalation reported {status_name(file_result.status)}")?
    let file_check = execute(session, ["test", "-e", denied_path.display()])?
    require(file_check.exit_code != 0, "failed file escalation created the destination")?
    print test_case("file escalation failure preserves the destination")

    let directory_spec = model.DirectorySpec(id: "denied-dir", path: denied_dir, mode: 0o700)
    let directory_result = dir.apply_remote(session, a.host, directory_spec)
    require(failed_or_partial(directory_result.status), f"failed directory escalation reported {status_name(directory_result.status)}")?
    let directory_check = execute(session, ["test", "-e", denied_dir.display()])?
    require(directory_check.exit_code != 0, "failed directory escalation created the destination")?
    print test_case("directory escalation failure preserves the destination")

    let package_spec = model.PackageSpec(id: "denied-package", name: "tree")
    let package_result = match package.apply_remote(session, a.host, package_spec, []) {
      Ok(value) => value.result,
      Err(failure) => { return Err(failure) },
    }
    require(failed_or_partial(package_result.status), f"failed package escalation reported {status_name(package_result.status)}")?
    match package.fact(session, package_spec)? {
      plan.Absent => {}
      _ => return Err(error.failure("failed package escalation installed the package")),
    }
    print test_case("package escalation failure is observed")

    let _ = execute(session, [@elevate, "userdel", denied_user])?
    let _ = execute(session, [@elevate, "rm", "-rf", denied_path.display(), denied_dir.display()])?
  }

  Ok()
}
