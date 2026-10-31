##! Native SSH integration checks against the disposable fixtures.

use xinfra.doctor as doctor
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

## Executes the transport acceptance checks.
export proc execute() [fs, process, env, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?
  let b = fixture("B")?

  with session = connect(a)? {
    let checks = doctor.doctor(session)?
    let failed = checks |> where { |check| !check.ok } |> count()
    require(failed == 0, f"doctor failed {failed} checks on xinfra-a")?
    print test_case("doctor xinfra-a")

    let result = transport.exec(session, ["sh", "-c", "printf out; printf err >&2; exit 7"])?
    require(result.exit_code == 7, "nonzero exit was not preserved")?
    require(result.stdout == b"out", "stdout was not preserved")?
    require(result.stderr == b"err", "stderr was not preserved")?
    print test_case("stdout/stderr/status")

    let argv = [
      "printf",
      "%s\n",
      "a b",
      "it's",
      "\"quoted\"",
      "$(echo nope)",
      "-leading",
      "line\nbreak",
    ]
    let hostile = transport.exec(session, argv)?
    let expected = "a b\nit's\n\"quoted\"\n$(echo nope)\n-leading\nline\nbreak\n"
    let hostile_text = hostile.stdout.utf8() ?? ""
    require(hostile_text == expected, "hostile argv did not round-trip")?
    print test_case("hostile argv")

    match transport.exec(session, ["printf", "a\0b"]) {
      Ok(_) => return Err("NUL argument was accepted"),
      Err(message) => require("NUL" in message, "NUL rejection was not explicit")?,
    }
    print test_case("NUL rejection")

    match transport.exec(session, ["sleep", "5"], 200) {
      Ok(_) => return Err("slow command did not time out"),
      Err(message) => require("timed out" in message, "timeout lost certainty")?,
    }
    print test_case("timeout certainty")

    let first = transport.exec(session, ["printenv", "SSH_CONNECTION"])?
    let second = transport.exec(session, ["printenv", "SSH_CONNECTION"])?
    require(first.stdout == second.stdout, "batch did not reuse one connection")?
    require(!first.stdout.is_empty(), "SSH_CONNECTION was empty")?
    print test_case("connection reuse")
  }

  with session = connect(b)? {
    let checks = doctor.doctor(session)?
    let failed = checks |> where { |check| !check.ok } |> count()
    require(failed == 0, f"doctor failed {failed} checks on xinfra-b")?
    print test_case("doctor xinfra-b")
    require(transport.exec(session, ["doas", "-n", "true"])?.exit_code == 0, "doas failed")?
    print test_case("doas")
  }

  match transport.connect_endpoint(a.host, a.port, a.username, a.key, b.host_key) {
    Ok(_) => return Err("wrong host key pin was accepted"),
    Err(_) => {}
  }
  print test_case("wrong host key rejected")

  let root = match fs.tempdir() {
    Ok(value) => value,
    Err(error) => { return Err(error.message) },
  }
  let directory = match root.host_path() {
    Ok(value) => value,
    Err(error) => { return Err(error.message) },
  }
  let key = fp"{directory}/wrong-key"
  let _keygen = match process.which("ssh-keygen") {
    Ok(value) => value,
    Err(error) => { return Err(error.message) },
  }
  let generated = try run.capture --text ssh-keygen -q -t ed25519 -N "" -f $key
  match generated {
    Ok(output) => require(output.status.ok, "ssh-keygen failed")?,
    Err(error) => { return Err(error.message) },
  }
  match transport.connect_endpoint(a.host, a.port, a.username, key, a.host_key) {
    Ok(_) => return Err("unauthorized key was accepted"),
    Err(_) => {}
  }
  print test_case("denied key rejected")

  Ok()
}
