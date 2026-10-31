##! Remote file staging and validation matrix.

use xinfra.host as host
use xinfra.model as model
use xinfra.plan as plan
use xinfra.remote as remote
use xinfra.resources.file as file
use xinfra.transport as transport
use xinfra.validate as validate

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

proc run_command(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Str] {
  transport.exec(session, argv)
}

proc inspect(session: transport.Session, target: Path) -> Result[host.Inspection, Str] {
  match remote.inspect_path(session, target) {
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

pure content(text: Str) -> validate.PreparedSource {
  validate.Content(validate.ContentSource(text: text, digest: hash.sha256(bytes.from_text(text)).hex()))
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the file matrix.
export proc check_files() [fs, process, env, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?
  let base = p"/home/xinfra/xinfra-r3b"

  with session = connect(a)? {
    let _ = run_command(session, ["rm", "-rf", base.display()])?
    let _ = run_command(session, ["mkdir", "-p", base.display()])?

    let live_path = fp"{base}/config"
    let spec = model.FileSpec(id: "config", path: live_path, mode: 0o640)
    let source = content("one\n")
    let first = file.apply_remote(session, a.host, spec, source)
    require(first.status == host.Changed and first.verified, f"first file apply failed: {status_name(first.status)} {first.cause ?? ""}")?
    let second = file.apply_remote(session, a.host, spec, source)
    require(second.status == host.Unchanged and second.verified, "second file apply was not unchanged")?
    print test_case("file first and second apply")

    let before = inspect(session, live_path)?
    let no_op = file.apply_remote(session, a.host, spec, source)
    let after = inspect(session, live_path)?
    require(no_op.status == host.Unchanged, "no-op file apply was not unchanged")?
    let before_stat = match before {
      host.Found(stat) => stat,
      host.Missing => { return Err("file vanished before no-op") },
    }
    let after_stat = match after {
      host.Found(stat) => stat,
      host.Missing => { return Err("file vanished during no-op") },
    }
    require(before_stat.mtime_ns == after_stat.mtime_ns, "no-op changed mtime")?
    print test_case("no-op leaves mtime")

    match inspect(session, live_path)? {
      host.Found(stat) => {
        require(stat.mode == 0o640, "file mode was not applied")?
        require(stat.kind == "file", "file kind was not verified")?
      }
      host.Missing => return Err("applied file is missing"),
    }
    print test_case("ownership and mode verification")

    let invalid_spec = model.FileSpec(
      id: "config",
      path: live_path,
      mode: 0o640,
      validate: model.Validation(argv: ["/bin/sh", "-c", "exit 1"]),
    )
    let invalid = file.apply_remote(session, a.host, invalid_spec, content("two\n"))
    require(invalid.status == host.Failed, "invalid staged file was promoted")?
    let live = inspect(session, live_path)?
    let expected = hash.sha256(bytes.from_text("one\n")).hex()
    match live {
      host.Found(stat) => require(stat.digest == expected, "validation failure changed the live file")?,
      host.Missing => return Err("validation failure removed the live file"),
    }
    print test_case("validation preserves live file")

    let missing = fp"{base}/missing-source"
    let missing_source = validate.Local(validate.LocalSource(path: missing, digest: "0"))
    let missing_spec = model.FileSpec(id: "missing", path: fp"{base}/missing-live", mode: 0o644)
    let partial = file.apply_remote(session, a.host, missing_spec, missing_source)
    require(partial.status == host.Partial or partial.status == host.Failed, "failed transfer reported success")?
    match inspect(session, fp"{base}/missing-live")? {
      host.Missing => {}
      host.Found(_) => return Err("failed transfer created the destination"),
    }
    let listing = run_command(session, ["sh", "-c", f"ls -A {base.display()} | grep '^\\.xinfra\\.' || true"])?
    require(listing.stdout.is_empty(), "failed transfer left owned staging")?
    print test_case("failed transfer preserves destination and cleans staging")

    let local = match fs.tempdir() {
      Ok(value) => value,
      Err(error) => { return Err(error.message) },
    }
    let local_root = match local.host_path() {
      Ok(value) => value,
      Err(error) => { return Err(error.message) },
    }
    let changed_artifact = fp"{local_root}/artifact.txt"
    match changed_artifact.write("planned\n") {
      Ok(_) => {}
      Err(error) => { return Err(error.message) },
    }
    let planned_digest = match hash.sha256(changed_artifact) {
      Ok(value) => value.hex(),
      Err(error) => { return Err(error.message) },
    }
    let planned_source = validate.Local(validate.LocalSource(path: changed_artifact, digest: planned_digest))
    match changed_artifact.write("changed after planning\n") {
      Ok(_) => {}
      Err(error) => { return Err(error.message) },
    }
    let changed_spec = model.FileSpec(id: "changed-source", path: fp"{base}/changed-source", mode: 0o600)
    let changed_source = file.apply_remote(session, a.host, changed_spec, planned_source)
    require(changed_source.status == host.Failed, "a source changed after planning was applied")?
    match inspect(session, fp"{base}/changed-source")? {
      host.Missing => {}
      host.Found(_) => return Err("a changed source created the destination"),
    }
    print test_case("source changes after planning are rejected")

    let root_parent_path = p"/etc/xinfra-r3b-owned"
    let _ = run_command(session, ["sudo", "-n", "sh", "-c", f"printf old > {root_parent_path.display()}; chown xinfra:xinfra {root_parent_path.display()}; chmod 644 {root_parent_path.display()}"])?
    let root_spec = model.FileSpec(
      id: "root-parent",
      path: root_parent_path,
      mode: 0o600,
      privilege: model.AsRoot,
    )
    let root_result = file.apply_remote(session, a.host, root_spec, content("new\n"), ["sudo", "-n"])
    require(root_result.status == host.Changed and root_result.verified, "app-owned child under a root parent failed")?
    let root_stat = run_command(session, ["stat", "-c", "%U|%G|%a", root_parent_path.display()])?
    require((root_stat.stdout.utf8() ?? "") == "xinfra|xinfra|600\n", "omitted owner or group was not preserved")?
    let _ = run_command(session, ["sudo", "-n", "rm", "-f", root_parent_path.display()])?
    print test_case("root parent and omitted ownership are preserved")

    let insecure = fp"{base}/insecure"
    let _ = run_command(session, ["mkdir", "-p", insecure.display()])?
    let _ = run_command(session, ["chmod", "777", insecure.display()])?
    let insecure_spec = model.FileSpec(id: "insecure", path: fp"{insecure}/config", mode: 0o644)
    let blocked = file.apply_remote(session, a.host, insecure_spec, content("x\n"))
    require(
      blocked.status == host.Blocked,
      f"trusted-parent check accepted mode 777: {status_name(blocked.status)} {blocked.cause ?? ""}",
    )?
    print test_case("trusted-parent rejection")

    let hostile_path = fp"{base}/a b'$(echo nope)'"
    let hostile_spec = model.FileSpec(id: "hostile", path: hostile_path, mode: 0o600)
    let hostile = file.apply_remote(session, a.host, hostile_spec, content("hostile\n"))
    require(hostile.status == host.Changed and hostile.verified, "hostile path file apply failed")?
    print test_case("hostile path quoting")

    let directory_conflict = fp"{base}/directory"
    let _ = run_command(session, ["mkdir", "-p", directory_conflict.display()])?
    let conflict_spec = model.FileSpec(id: "conflict", path: directory_conflict, mode: 0o644)
    let conflict = file.apply_remote(session, a.host, conflict_spec, content("x\n"))
    require(conflict.status == host.Blocked, "file/directory conflict was not blocked")?
    print test_case("file/directory type conflict")

    let absent_spec = model.FileSpec(id: "config", path: live_path, state: model.Absent)
    let removed = file.apply_remote(session, a.host, absent_spec, null)
    require(removed.status == host.Changed and removed.verified, "absent file was not removed")?
    print test_case("file absence")

    let artifact_dir = match fs.tempdir() {
      Ok(value) => value,
      Err(error) => { return Err(error.message) },
    }
    let artifact_root = match artifact_dir.host_path() {
      Ok(value) => value,
      Err(error) => { return Err(error.message) },
    }
    let artifact = fp"{artifact_root}/large.bin"
    let created = try run.capture --text dd if=/dev/zero of=$artifact bs=1048576 count=128
    match created {
      Ok(output) => require(output.status.ok, "large artifact creation failed")?,
      Err(error) => { return Err(error.message) },
    }
    let digest = match hash.sha256(artifact) {
      Ok(value) => value.hex(),
      Err(error) => { return Err(error.message) },
    }
    let large_spec = model.FileSpec(id: "large", path: fp"{base}/large.bin", mode: 0o640)
    let large_source = validate.Local(validate.LocalSource(path: artifact, digest: digest))
    let large = file.apply_remote(session, a.host, large_spec, large_source)
    require(large.status == host.Changed and large.verified, f"128 MiB transfer failed: {status_name(large.status)} {large.cause ?? ""}")?
    match inspect(session, fp"{base}/large.bin")? {
      host.Found(stat) => {
        require(stat.size == 134217728, "128 MiB size mismatch")?
        require(stat.digest == digest, "128 MiB digest mismatch")?
      }
      host.Missing => return Err("128 MiB artifact is missing"),
    }
    print test_case("128 MiB binary artifact")

    let _ = run_command(session, ["rm", "-rf", base.display()])?
  }

  Ok()
}
