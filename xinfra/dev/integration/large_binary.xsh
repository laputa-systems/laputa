##! Binary transfer larger than the default capture limit.

use xinfra.host as host
use xinfra.model as model
use xinfra.remote as remote
use xinfra.resources.file as file
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

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Execute the large binary scenario.
export proc check_large_binary() [fs, process, env, error, io] -> Result[Unit, Error] {
  let a = fixture("A")?
  let base = p"/home/xinfra/xinfra-q2-large"

  with session = connect(a)? {
    let _ = execute(session, ["rm", "-rf", base.display()])?
    let _ = execute(session, ["mkdir", "-p", base.display()])?

    let local = fs.tempdir()?
    let local_root = local.host_path()?
    let artifact = fp"{local_root}/large.bin"
    let created = try run.capture --text dd if=/dev/zero of=$artifact bs=1048576 count=128
    match created {
      Ok(output) => require(output.status.ok, "large artifact creation failed")?,
      Err(failure) => { return Err(error.failure(failure.message)) },
    }
    let digest = match hash.sha256(artifact) {
      Ok(value) => value.hex(),
      Err(failure) => { return Err(error.failure(failure.message)) },
    }
    require(digest.byte_len() == 64, "artifact digest is malformed")?

    let destination = fp"{base}/large.bin"
    let source = validate.Local(validate.LocalSource(path: artifact, digest: digest))
    let spec = model.FileSpec(id: "large", path: destination, mode: 0o640)
    let first = file.apply_remote(session, a.host, spec, source)
    require(first.status == host.Changed and first.verified, "large transfer failed")?
    match inspect(session, destination)? {
      host.Found(stat) => {
        require(stat.kind == "file", "large artifact is not a file")?
        require(stat.size == 134217728, "large artifact size differs")?
        require(stat.digest == digest, "large artifact digest differs")?
        require(stat.mode == 0o640, "large artifact mode differs")?
      }
      host.Missing => return Err(error.failure("large artifact is missing")),
    }
    print test_case("128 MiB binary transfer")

    let second = file.apply_remote(session, a.host, spec, source)
    require(second.status == host.Unchanged, "second large transfer was not a no-op")?
    print test_case("128 MiB no-op by digest")

    let _ = execute(session, ["rm", "-rf", base.display()])?
  }

  Ok()
}
