##! Secret staging, stdin, and reporting hardening.

use xinfra.host as host
use xinfra.model as model
use xinfra.outcome as outcome
use xinfra.redact as redact
use xinfra.report as report
use xinfra.resources.command as command
use xinfra.resources.file as file
use xinfra.secret as secret
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

proc connect(fixture: Fixture) [error] -> Result[transport.Session, Error] {
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

proc apply_file(session: transport.Session, host_name: Str, spec: model.FileSpec, source: validate.PreparedSource) -> Result[host.ApplyResult, Error] {
  Ok(file.apply_remote(session, host_name, spec, source))
}

proc apply_command(session: transport.Session, host_name: Str, spec: model.CommandSpec) -> Result[host.ApplyResult, Error] {
  command.apply_remote(session, host_name, spec, [], true)
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the secret and reporting matrix.
export proc check_secrets() [fs, process, env, error, io] -> Result[Unit, Error] {
  let a = fixture("A")?
  let base = p"/home/xinfra/xinfra-r7"
  let canary = "canary-value"

  with session = connect(a)? {
    let _ = execute(session, ["rm", "-rf", base.display()])?
    let _ = execute(session, ["mkdir", "-p", base.display()])?

    env XINFRA_SECRET=$canary {
      let secret_path = fp"{base}/secret"
      let validator = model.Validation(argv: ["sh", "-c", r"""test "$(stat -c %a "$0")" = 600"""])
      let spec = model.FileSpec(id: "secret", path: secret_path, mode: 0o600, validate: validator)
      let first = apply_file(session, a.host, spec, validate.Secret(model.FromEnv("XINFRA_SECRET")))?
      require(first.status == host.Changed and first.verified, "secret file was not staged")?
      let second = apply_file(session, a.host, spec, validate.Secret(model.FromEnv("XINFRA_SECRET")))?
      require(second.status == host.Unchanged, "unchanged secret was not a no-op")?
      let content = execute(session, ["cat", secret_path.display()])?
      require((content.stdout.utf8() ?? "") == canary, "secret content changed")?
      print test_case("secret file staging is 0600 and no-op")

      let stdin_path = fp"{base}/stdin"
      let stdin_spec = model.CommandSpec(
        id: "stdin",
        argv: ["sh", "-c", f"cat > {stdin_path.display()}"],
        stdin_secret: model.FromEnv("XINFRA_SECRET"),
      )
      let stdin_result = apply_command(session, a.host, stdin_spec)?
      require(stdin_result.status == host.Changed, "secret stdin command failed")?
      let stdin_content = execute(session, ["cat", stdin_path.display()])?
      require((stdin_content.stdout.utf8() ?? "") == canary, "secret stdin was not delivered")?
      print test_case("secret only through command stdin")
    }

    let local = match fs.tempdir() {
      Ok(value) => value,
      Err(error) => { return Err(error) },
    }
    let local_path = fp"{local.host_path()?}/secret"
    let _ = local_path.write("file-canary")?
    let _ = local_path.chmod(0o600)?
    let file_path = fp"{base}/file-secret"
    let file_spec = model.FileSpec(id: "file-secret", path: file_path, mode: 0o600)
    let file_result = apply_file(session, a.host, file_spec, validate.Secret(model.FromFile(local_path)))?
    require(file_result.status == host.Changed, "file-referenced secret failed")?
    let file_content = execute(session, ["cat", file_path.display()])?
    require((file_content.stdout.utf8() ?? "") == "file-canary", "file-referenced secret content changed")?
    print test_case("secret file reference")

    let redactor = redact.with_secret(redact.empty(), canary)
    let row = report.row("run-1", "host\x1b[31m", "resource", "apply", outcome.Failed, false, f"leaked {canary}", 1)
    let built = report.build("run-1", [row], 1)
    let human = report.render(built, report.Human, redactor)?
    let json_text = report.render(built, report.Json, redactor)?
    let jsonl = report.render(built, report.Jsonl, redactor)?
    require(canary not in human and canary not in json_text and canary not in jsonl, "secret leaked in report output")?
    require("\x1b" not in human and "\x1b" not in json_text and "\x1b" not in jsonl, "control sequence survived")?
    require("[redacted]" in human, "redaction marker missing")?
    print test_case("human, JSON, and JSONL redaction")

    let pieces: List[Str] = collect { for index in range(5000) { let _ = index; yield "x" } }
    let long_cause = pieces.join("")
    let long_row = report.row("run-2", "host", "resource", "apply", outcome.Failed, false, long_cause, 1)
    let long_report = report.render(report.build("run-2", [long_row], 1), report.Human, redact.empty())?
    require("truncated" in long_report, "overlong field was not truncated")?
    require(long_report.byte_len() < 5000, "overlong field remained unbounded")?
    print test_case("overlong fields are bounded")

    let primary = report.primary_failure(f"primary {canary}", "cleanup failed")
    require(canary not in redact.redact(primary, redactor), "primary failure was not redacted")?
    require(redact.redact(primary, redactor).starts_with("primary"), "cleanup replaced the primary failure")?
    print test_case("primary failure survives cleanup")

    let _ = execute(session, ["rm", "-rf", base.display()])?
  }

  Ok()
}
