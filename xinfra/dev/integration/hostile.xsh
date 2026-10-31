##! Hostile argv and path handling.

use xinfra.host as host
use xinfra.model as model
use xinfra.remote as remote
use xinfra.resources.dir as dir
use xinfra.resources.file as file
use xinfra.resources.symlink as symlink
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

proc inspect(session: transport.Session, target: Path) -> Result[host.Inspection, Error] {
  remote.inspect_path(session, target)
}

pure content(text: Str) -> validate.PreparedSource {
  validate.Content(validate.ContentSource(text: text, digest: hash.sha256(bytes.from_text(text)).hex()))
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Execute the hostile input scenario.
export proc check_hostile() [fs, process, env, error, io] -> Result[Unit, Error] {
  let a = fixture("A")?
  let base = p"/home/xinfra/xinfra-q2-hostile"

  with session = connect(a)? {
    let _ = execute(session, ["rm", "-rf", base.display()])?
    let _ = execute(session, ["mkdir", "-p", base.display()])?

    let argv = [
      "printf",
      "%s\n",
      "a b",
      "it's",
      "\"quoted\"",
      "$(echo nope)",
      "-leading",
      "line\nbreak",
      "",
    ]
    let result = execute(session, argv)?
    let expected = "a b\nit's\n\"quoted\"\n$(echo nope)\n-leading\nline\nbreak\n\n"
    require((result.stdout.utf8() ?? "") == expected, "hostile argv did not round-trip")?
    print test_case("hostile argv")

    let directory = fp"{base}/a b'$(echo nope)' -leading"
    let directory_result = dir.apply_remote(session, a.host, model.DirectorySpec(id: "hostile-dir", path: directory, mode: 0o750))
    require(directory_result.status == host.Changed and directory_result.verified, "hostile directory failed")?
    match inspect(session, directory)? {
      host.Found(stat) => require(stat.kind == "dir" and stat.mode == 0o750, "hostile directory state differs")?,
      host.Missing => return Err(error.failure("hostile directory is missing")),
    }
    print test_case("hostile directory path")

    let file_path = fp"{directory}/-leading file"
    let content_value = content("first\n\nlast\n")
    let file_result = file.apply_remote(
      session,
      a.host,
      model.FileSpec(id: "hostile-file", path: file_path, mode: 0o640),
      content_value,
    )
    require(file_result.status == host.Changed and file_result.verified, "hostile file failed")?
    let read_back = execute(session, ["cat", file_path.display()])?
    require((read_back.stdout.utf8() ?? "") == "first\n\nlast\n", "hostile file content differs")?
    print test_case("hostile file content")

    let link_path = fp"{directory}/link with quotes'"
    let link_result = symlink.apply_remote(
      session,
      a.host,
      model.SymlinkSpec(id: "hostile-link", path: link_path, target: file_path),
    )
    require(link_result.status == host.Changed and link_result.verified, "hostile symlink failed")?
    print test_case("hostile symlink target")

    match execute(session, ["printf", "a\0b"]) {
      Ok(_) => return Err(error.failure("NUL argv was accepted")),
      Err(failure) => require("NUL" in failure.message, "NUL rejection was not explicit")?,
    }
    print test_case("NUL rejection")

    let _ = execute(session, ["rm", "-rf", base.display()])?
  }

  Ok()
}
