use infra.lock
use infra.model
use infra.testing
use infra.transport

const deploy_template = r"""##! A single-resource deployment for the cancellation scenario.
use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [
BODY
  ]
}
"""

const quick_service_script = r"""#!/sbin/openrc-run
description="xsh-infra cancellation scenario service"
command=/bin/sleep
command_args="3600"
command_background=true
pidfile=/run/${RC_SVCNAME}.pid
"""

const notify_service_script = r"""#!/sbin/openrc-run
description="xsh-infra cancellation scenario service"
command=/bin/sleep
command_args="3600"
command_background=true
extra_started_commands="reload"
pidfile=/run/${RC_SVCNAME}.pid

reload() {
  touch /var/tmp/${RC_SVCNAME}.reloading
  sleep 30
}
"""

const gate_script = "touch $0/started; while [ -e $0/hold ]; do sleep 1; done; touch $0/finished"

type Invocation = {code: Int, stdout: Str, stderr: Str}

type Cancelled = {code: Int, stdout: Str, stderr: Str}

proc inventory() [env, error] -> Result[Path, Error] {
  Ok(fp"{env.get("XINFRA_TEST_INVENTORY")?}")
}

proc apply_args(inventory: Path, deploy: Path, limit: Str, lock_path: Str) -> List[Str] {
  ["bin/xinfra.xsh", "apply", f"{inventory}", f"{deploy}", "--limit", limit, "--lock-path", lock_path, "--format", "jsonl", "--jobs", "1"]
}

proc write_deploy(dir: Path, body: Str) [fs, error] -> Result[Path, Error] {
  let file = fp"{dir}/deploy.xsh"
  file.write(deploy_template.replace("BODY", with: body))
  Ok(file)
}

proc spawn_apply(
  dir: Path,
  inventory: Path,
  deploy: Path,
  limit: Str,
  lock_path: Str,
) [fs, process, error] -> Result[ProcessHandle, ProcessError] {
  let out = fp"{dir}/apply.out"
  let err = fp"{dir}/apply.err"
  out.remove(missing_ok: true)
  err.remove(missing_ok: true)
  let command = process.command_argv(
    "xsh",
    ["xsh"] + apply_args(inventory, deploy, limit, lock_path),
    p".",
    {},
    b"",
    out,
    err,
  )
  spawn command
}

proc collect(dir: Path, code: Int) [fs, error] -> Result[Cancelled, Error] {
  Ok(Cancelled(code:, stdout: fp"{dir}/apply.out".read_text()?, stderr: fp"{dir}/apply.err".read_text()?))
}

proc wait_for_remote(host: model.Host, script: Str, args: List[Str], limit_ms: Int) [env, process, time, error] -> Result[Bool, Error] {
  let connection = transport.connect(host)?
  let started = time.now()
  var found = false
  while time.now() - started < limit_ms {
    let execution = transport.exec(connection, script, args)?
    if (execution.stdout.utf8() ?? "") == "yes\n" {
      found = true
      break
    }

    time.sleep(50ms)
  }

  let _ = transport.disconnect(connection)
  Ok(found)
}

proc lost_patience(handle: ProcessHandle) [process, error] -> Result[Unit, Error] {
  let _ = process.kill(handle.pid, signal: "KILL")
  let _ = wait handle?
}

proc apply_again(
  dir: Path,
  inventory: Path,
  host: model.Host,
  deploy: Path,
  lock_path: Str,
) [fs, process, error] -> Result[Invocation, Error] {
  let out = run.capture --text xsh @(apply_args(inventory, deploy, host.name, lock_path))
  Ok(Invocation(code: out.status.exit_code()?, stdout: out.stdout, stderr: out.stderr))
}

proc apply_again_with_apk_lock_retry(
  dir: Path,
  inventory: Path,
  host: model.Host,
  deploy: Path,
  lock_path: Str,
) [fs, process, time, error] -> Result[Invocation, Error] {
  var attempt = 0
  var result = apply_again(dir, inventory, host, deploy, lock_path)?
  while result.code != 0 and "Unable to lock database" in result.stdout and attempt < 4 {
    attempt += 1
    time.sleep(500ms)
    result = apply_again(dir, inventory, host, deploy, lock_path)?
  }

  Ok(result)
}

proc assert_lock_free(host: model.Host, lock_path: Str) [env, process, error] -> Result[Unit, Error] {
  let connection = transport.connect(host)?
  let held = lock.inspect(connection, lock_path)?
  let _ = transport.disconnect(connection)
  assert held == null, f"the lock {lock_path} was not released: {held ?? ""}"
}

proc exists(host: model.Host, target: Str) [env, process, error] -> Result[Bool, Error] {
  Ok(testing.remote_text(host, "test -e \"$1\" && echo yes || echo no", [target])? == "yes\n")
}

proc mode(host: model.Host, target: Str) [env, process, error] -> Result[Str, Error] {
  testing.remote_text(host, "stat -c %a -- \"$1\"", [target], privileged: true)
}

proc boundary_signal(direction: Str) -> Str {
  if direction == "after" { "INT" } else { "TERM" }
}

proc assert_entry_status(cancelled: Cancelled, id: Str, kind: Str, status: Str) [error] {
  assert f"  {id} [{kind}] {status}" in cancelled.stderr, cancelled.stderr
}

proc assert_cancelled(cancelled: Cancelled, id: Str, kind: Str) [error] {
  assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stdout}{cancelled.stderr}"
  assert_entry_status(cancelled, id, kind, "unknown")
  assert "cancelled" in cancelled.stderr, cancelled.stderr
}

proc rerun_status(invocation: Invocation, id: Str) [error] -> Str {
  for line in invocation.stdout.lines() {
    if line.trim() == "" {
      continue
    }

    let record = json.decode(line)?.require(Record)?
    let kind = record.get("type")?.require(Str)?
    if kind == "entry" {
      let identity = record.get("id")?.require(Str)?
      if identity == id {
        return record.get("status")?.require(Str)?
      }
    }
  }

  "missing"
}

proc gate_decl(mark: Str, needs: List[Str]) -> Str {
  let quoted = needs |> map { |id| f"\"{id}\"" } |> collect()
  let needs_text = if needs.is_empty() { "" } else { f", needs: [{quoted.join(", ")}]" }
  f"    declare.command(id: \"gate\", argv: [\"sh\", \"-c\", \"{gate_script}\", \"{mark}\"], always: true, timeout_seconds: 120{needs_text})?,"
}

proc apply_cancelled_at_gate(
  dir: Path,
  inventory: Path,
  host: model.Host,
  deploy: Path,
  lock_path: Str,
  mark: Str,
  signal: Str,
) [fs, env, process, time, error] -> Result[Cancelled, Error] {
  let _ = testing.remote_text(host, "mkdir -p -- \"$1\" && : > \"$1/hold\"", [mark])?
  let handle = spawn_apply(dir, inventory, deploy, host.name, lock_path)?
  let reached = wait_for_remote(host, "test -e \"$1\" && echo yes || echo no", [f"{mark}/started"], 60000)?
  if ! reached {
    lost_patience(handle)?
  }

  assert reached, f"the apply never reached the gate at {mark}"
  process.kill(handle.pid, signal: signal)?
  let status = wait handle?
  let code = status.exit_code() ?? -1
  let _ = testing.remote_text(host, "rm -f -- \"$1/hold\"", [mark])?
  collect(dir, code)
}

proc cancelled_inflight(
  dir: Path,
  inventory: Path,
  host: model.Host,
  deploy: Path,
  lock_path: Str,
  script: Str,
  args: List[Str],
  signal: Str,
) [fs, env, process, time, error] -> Result[Cancelled, Error] {
  let handle = spawn_apply(dir, inventory, deploy, host.name, lock_path)?
  let reached = wait_for_remote(host, script, args, 60000)?
  if ! reached {
    lost_patience(handle)?
  }

  assert reached, "the mutation never reached its in-flight marker"
  process.kill(handle.pid, signal: signal)?
  let status = wait handle?
  let code = status.exit_code() ?? -1
  collect(dir, code)
}

proc directory_body(base: Str, mark: Str, direction: Str) -> Str {
  if direction == "before" {
    [
      gate_decl(mark, []),
      f"    declare.directory(id: \"target\", at: \"{base}\", mode: 0o750, parents: true, needs: [\"gate\"])?,",
    ].join("\n")
  } else {
    [
      f"    declare.directory(id: \"target\", at: \"{base}\", mode: 0o750, parents: true)?,",
      gate_decl(mark, ["target"]),
    ].join("\n")
  }
}

test cancellation_before_and_after_a_directory_is_reported_from_the_target_side_and_converges { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  for direction in ["before", "after"] {
    let base = f"/var/tmp/{testing.scratch_name(dir)}-directory-{direction}"
    let mark = f"{base}.mark"
    let lock_path = f"{base}.lock"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
    let deploy = write_deploy(dir, directory_body(base, mark, direction))?
    let cancelled = apply_cancelled_at_gate(dir, inventory, host, deploy, lock_path, mark, boundary_signal(direction))?
    assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stderr}"
    assert_entry_status(cancelled, "gate", "command", "unknown")
    if direction == "before" {
      assert_entry_status(cancelled, "target", "directory", "blocked")
      assert ! exists(host, base)?
    } else {
      assert_entry_status(cancelled, "target", "directory", "changed")
      assert mode(host, base)? == "750\n"
    }
    assert_lock_free(host, lock_path)?
    let again = apply_again(dir, inventory, host, deploy, lock_path)?
    assert again.code == 0, again.stderr
    if direction == "before" {
      assert rerun_status(again, "target") == "changed"
    } else {
      assert rerun_status(again, "target") == "unchanged"
    }
    assert mode(host, base)? == "750\n"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
  }
}

proc file_body(base: Str, mark: Str, direction: Str) -> Str {
  let base_line = f"    declare.directory(id: \"base\", at: \"{base}\", parents: true)?,"
  if direction == "before" {
    [
      base_line,
      gate_decl(mark, ["base"]),
      f"    declare.file(id: \"target\", at: \"{base}/motd\", text: \"hello\\n\", mode: 0o640, needs: [\"base\", \"gate\"])?,",
    ].join("\n")
  } else {
    [
      base_line,
      f"    declare.file(id: \"target\", at: \"{base}/motd\", text: \"hello\\n\", mode: 0o640, needs: [\"base\"])?,",
      gate_decl(mark, ["target"]),
    ].join("\n")
  }
}

test cancellation_before_and_after_a_file_is_reported_from_the_target_side_and_converges { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  for direction in ["before", "after"] {
    let base = f"/var/tmp/{testing.scratch_name(dir)}-file-{direction}"
    let mark = f"{base}.mark"
    let lock_path = f"{base}.lock"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
    let deploy = write_deploy(dir, file_body(base, mark, direction))?
    let cancelled = apply_cancelled_at_gate(dir, inventory, host, deploy, lock_path, mark, boundary_signal(direction))?
    assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stderr}"
    assert_entry_status(cancelled, "gate", "command", "unknown")
    if direction == "before" {
      assert_entry_status(cancelled, "target", "file", "blocked")
      assert ! exists(host, f"{base}/motd")?
    } else {
      assert_entry_status(cancelled, "target", "file", "changed")
      assert testing.remote_text(host, "cat \"$1\"/motd", [base], privileged: true)? == "hello\n"
    }
    assert_lock_free(host, lock_path)?
    let again = apply_again(dir, inventory, host, deploy, lock_path)?
    assert again.code == 0, again.stderr
    if direction == "before" {
      assert rerun_status(again, "target") == "changed"
    } else {
      assert rerun_status(again, "target") == "unchanged"
    }
    assert testing.remote_text(host, "cat \"$1\"/motd", [base], privileged: true)? == "hello\n"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
  }
}

proc symlink_body(base: Str, mark: Str, direction: Str) -> Str {
  let base_line = f"    declare.directory(id: \"base\", at: \"{base}\", parents: true)?,"
  let source_line = f"    declare.file(id: \"source\", at: \"{base}/source\", text: \"x\\n\", needs: [\"base\"])?,"
  if direction == "before" {
    [
      base_line,
      source_line,
      gate_decl(mark, ["source"]),
      f"    declare.symlink(id: \"target\", at: \"{base}/link\", target: \"source\", needs: [\"source\", \"gate\"])?,",
    ].join("\n")
  } else {
    [
      base_line,
      source_line,
      f"    declare.symlink(id: \"target\", at: \"{base}/link\", target: \"source\", needs: [\"source\"])?,",
      gate_decl(mark, ["target"]),
    ].join("\n")
  }
}

test cancellation_before_and_after_a_symlink_is_reported_from_the_target_side_and_converges { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  for direction in ["before", "after"] {
    let base = f"/var/tmp/{testing.scratch_name(dir)}-symlink-{direction}"
    let mark = f"{base}.mark"
    let lock_path = f"{base}.lock"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
    let deploy = write_deploy(dir, symlink_body(base, mark, direction))?
    let cancelled = apply_cancelled_at_gate(dir, inventory, host, deploy, lock_path, mark, boundary_signal(direction))?
    assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stderr}"
    assert_entry_status(cancelled, "gate", "command", "unknown")
    if direction == "before" {
      assert_entry_status(cancelled, "target", "symlink", "blocked")
      assert ! exists(host, f"{base}/link")?
    } else {
      assert_entry_status(cancelled, "target", "symlink", "changed")
      assert testing.remote_text(host, "readlink -- \"$1/link\"", [base], privileged: true)? == "source\n"
    }
    assert_lock_free(host, lock_path)?
    let again = apply_again(dir, inventory, host, deploy, lock_path)?
    assert again.code == 0, again.stderr
    if direction == "before" {
      assert rerun_status(again, "target") == "changed"
    } else {
      assert rerun_status(again, "target") == "unchanged"
    }
    assert testing.remote_text(host, "readlink -- \"$1/link\"", [base], privileged: true)? == "source\n"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
  }
}

proc command_body(base: Str, mark: Str, direction: Str) -> Str {
  let base_line = f"    declare.directory(id: \"base\", at: \"{base}\", parents: true)?,"
  let target_line = f"    declare.command(id: \"target\", argv: [\"sh\", \"-c\", \"echo x >> \\\"$0/log\\\"; touch \\\"$0/created\\\"\", \"{base}\"], creates: \"{base}/created\", needs: [\"base\"])?,"
  if direction == "before" {
    [
      base_line,
      gate_decl(mark, ["base"]),
      f"    declare.command(id: \"target\", argv: [\"sh\", \"-c\", \"echo x >> \\\"$0/log\\\"; touch \\\"$0/created\\\"\", \"{base}\"], creates: \"{base}/created\", needs: [\"base\", \"gate\"])?,",
    ].join("\n")
  } else {
    [
      base_line,
      target_line,
      gate_decl(mark, ["target"]),
    ].join("\n")
  }
}

test cancellation_before_and_after_a_command_is_reported_from_the_target_side_and_never_replays { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  for direction in ["before", "after"] {
    let base = f"/var/tmp/{testing.scratch_name(dir)}-command-{direction}"
    let mark = f"{base}.mark"
    let lock_path = f"{base}.lock"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
    let deploy = write_deploy(dir, command_body(base, mark, direction))?
    let cancelled = apply_cancelled_at_gate(dir, inventory, host, deploy, lock_path, mark, boundary_signal(direction))?
    assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stderr}"
    assert_entry_status(cancelled, "gate", "command", "unknown")
    if direction == "before" {
      assert_entry_status(cancelled, "target", "command", "blocked")
      assert ! exists(host, f"{base}/created")?
    } else {
      assert_entry_status(cancelled, "target", "command", "changed")
      assert exists(host, f"{base}/created")?
      assert testing.remote_text(host, "wc -l < \"$1/log\"", [base])? == "1\n"
    }
    assert_lock_free(host, lock_path)?
    let again = apply_again(dir, inventory, host, deploy, lock_path)?
    assert again.code == 0, again.stderr
    if direction == "before" {
      assert rerun_status(again, "target") == "changed"
    } else {
      assert rerun_status(again, "target") == "skipped"
    }
    assert testing.remote_text(host, "wc -l < \"$1/log\"", [base])? == "1\n"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
  }
}

proc held_command_body(base: Str, mark: Str) -> Str {
  [
    f"    declare.directory(id: \"base\", at: \"{base}\", parents: true)?,",
    f"    declare.command(id: \"target\", argv: [\"sh\", \"-c\", \"echo x >> $0/log; touch $1/started; while [ -e $1/hold ]; do sleep 1; done; touch $1/finished\", \"{base}\", \"{mark}\"], always: true, timeout_seconds: 120, needs: [\"base\"])?,",
    f"    declare.file(id: \"after\", at: \"{base}/after\", text: \"x\\n\", needs: [\"target\"])?,",
  ].join("\n")
}

test an_in_flight_command_cancellation_is_unknown_blocks_dependents_and_is_not_replayed { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  let base = f"/var/tmp/{testing.scratch_name(dir)}-inflight-command"
  let mark = f"{base}.mark"
  let lock_path = f"{base}.lock"
  let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
  let _ = testing.remote_text(host, "mkdir -p -- \"$1\" && : > \"$1/hold\"", [mark])?
  let deploy = write_deploy(dir, held_command_body(base, mark))?
  let cancelled = cancelled_inflight(
    dir,
    inventory,
    host,
    deploy,
    lock_path,
    "test -e \"$1\" && echo yes || echo no",
    [f"{mark}/started"],
    "TERM",
  )?
  assert_cancelled(cancelled, "target", "command")
  assert_entry_status(cancelled, "after", "file", "blocked")
  assert ! exists(host, f"{mark}/finished")?
  assert ! exists(host, f"{base}/after")?
  assert testing.remote_text(host, "wc -l < \"$1/log\"", [base])? == "1\n"
  assert_lock_free(host, lock_path)?
  let _ = testing.remote_text(host, "rm -f -- \"$1/hold\"", [mark])?
  let again = apply_again(dir, inventory, host, deploy, lock_path)?
  assert again.code == 0, again.stderr
  assert rerun_status(again, "target") == "changed"
  assert exists(host, f"{mark}/finished")?
  assert exists(host, f"{base}/after")?
  assert testing.remote_text(host, "wc -l < \"$1/log\"", [base])? == "2\n"
  let _ = testing.remote_text(host, "rm -rf -- \"$1\" \"$2\"", [base, mark], privileged: true)?
}

proc file_stream_body(base: Str, blob: Path) -> Str {
  [
    f"    declare.directory(id: \"base\", at: \"{base}\", parents: true)?,",
    f"    declare.file(id: \"target\", at: \"{base}/artifact.bin\", source: p\"{blob}\", mode: 0o600, needs: [\"base\"])?,",
  ].join("\n")
}

test an_in_flight_file_transfer_cancellation_is_unknown_and_never_publishes_a_partial_file { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  let base = f"/var/tmp/{testing.scratch_name(dir)}-inflight-file"
  let blob = fp"{dir}/artifact.bin"
  run dd if=/dev/urandom of=$blob bs=1M count=40 status=none
  let deploy = write_deploy(dir, file_stream_body(base, blob))?
  let lock_path = f"{base}.lock"
  let _ = testing.remote_text(host, "rm -rf -- \"$1\"", [base], privileged: true)?
  let cancelled = cancelled_inflight(
    dir,
    inventory,
    host,
    deploy,
    lock_path,
    "ls -A \"$1\" | grep -q '^.xinfra.' && echo yes || echo no",
    [base],
    "INT",
  )?
  assert_cancelled(cancelled, "target", "file")
  if exists(host, f"{base}/artifact.bin")? {
    assert testing.remote_text(host, "sha256sum < \"$1/artifact.bin\"", [base], privileged: true)?.fields()[0] == hash.sha256(blob)?.hex()
  }
  assert_lock_free(host, lock_path)?
  let again = apply_again(dir, inventory, host, deploy, lock_path)?
  assert again.code == 0, again.stderr
  assert testing.remote_text(host, "sha256sum < \"$1/artifact.bin\"", [base], privileged: true)?.fields()[0] == hash.sha256(blob)?.hex()
  let _ = testing.remote_text(host, "rm -rf -- \"$1\"", [base], privileged: true)?
}

proc package_body(mark: Str, direction: Str) -> Str {
  if direction == "before" {
    [
      gate_decl(mark, []),
      "    declare.package(id: \"target\", name: \"zstd\", needs: [\"gate\"])?,",
    ].join("\n")
  } else {
    [
      "    declare.package(id: \"target\", name: \"zstd\")?,",
      gate_decl(mark, ["target"]),
    ].join("\n")
  }
}

proc package_index_body(mark: Str, direction: Str) -> Str {
  if direction == "before" {
    [
      gate_decl(mark, []),
      "    declare.package_index(id: \"target\", needs: [\"gate\"])?,",
    ].join("\n")
  } else {
    [
      "    declare.package_index(id: \"target\")?,",
      gate_decl(mark, ["target"]),
    ].join("\n")
  }
}

test cancellation_before_and_after_a_package_and_package_index_is_reported_and_converges { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  for direction in ["before", "after"] {
    let base = f"/var/tmp/{testing.scratch_name(dir)}-package-{direction}"
    let mark = f"{base}.mark"
    let lock_path = f"{base}.lock"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\"", [mark], privileged: true)?
    let _ = testing.remote_text(host, "apk del -q zstd >/dev/null 2>&1 || true", [], privileged: true)?
    let deploy = write_deploy(dir, package_body(mark, direction))?
    let cancelled = apply_cancelled_at_gate(dir, inventory, host, deploy, lock_path, mark, boundary_signal(direction))?
    assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stderr}"
    assert_entry_status(cancelled, "gate", "command", "unknown")
    if direction == "before" {
      assert_entry_status(cancelled, "target", "package", "blocked")
      assert testing.remote_text(host, "apk info -e zstd || echo absent", [], privileged: true)? == "absent\n"
    } else {
      assert_entry_status(cancelled, "target", "package", "changed")
      assert testing.remote_text(host, "apk info -e zstd", [], privileged: true)? == "zstd\n"
    }
    assert_lock_free(host, lock_path)?
    let again = apply_again_with_apk_lock_retry(dir, inventory, host, deploy, lock_path)?
    assert again.code == 0, f"{again.stderr}\n{again.stdout}"
    if direction == "before" {
      assert rerun_status(again, "target") == "changed"
    } else {
      assert rerun_status(again, "target") == "unchanged"
    }
    assert testing.remote_text(host, "apk info -e zstd", [], privileged: true)? == "zstd\n"
    let _ = testing.remote_text(host, "apk del -q zstd >/dev/null 2>&1 || true", [], privileged: true)?
  }

  for direction in ["before", "after"] {
    let base = f"/var/tmp/{testing.scratch_name(dir)}-index-{direction}"
    let mark = f"{base}.mark"
    let lock_path = f"{base}.lock"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\"", [mark], privileged: true)?
    let deploy = write_deploy(dir, package_index_body(mark, direction))?
    let cancelled = apply_cancelled_at_gate(dir, inventory, host, deploy, lock_path, mark, boundary_signal(direction))?
    assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stderr}"
    assert_entry_status(cancelled, "gate", "command", "unknown")
    if direction == "before" {
      assert_entry_status(cancelled, "target", "package-index", "blocked")
    } else {
      assert_entry_status(cancelled, "target", "package-index", "changed")
    }
    assert_lock_free(host, lock_path)?
    let again = apply_again_with_apk_lock_retry(dir, inventory, host, deploy, lock_path)?
    assert again.code == 0, again.stderr
    assert rerun_status(again, "target") == "changed"
  }
}

proc group_body(name: Str, mark: Str, direction: Str) -> Str {
  if direction == "before" {
    [
      gate_decl(mark, []),
      f"    declare.group_account(id: \"target\", name: \"{name}\", gid: 4321, needs: [\"gate\"])?,",
    ].join("\n")
  } else {
    [
      f"    declare.group_account(id: \"target\", name: \"{name}\", gid: 4321)?,",
      gate_decl(mark, ["target"]),
    ].join("\n")
  }
}

test cancellation_before_and_after_a_group_is_reported_from_the_target_side_and_converges { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  let token = testing.scratch_name(dir).replace("-", with: "")
  let name = f"xg{token.byte_slice(0, 10)}"
  for direction in ["before", "after"] {
    let base = f"/var/tmp/{testing.scratch_name(dir)}-group-{direction}"
    let mark = f"{base}.mark"
    let lock_path = f"{base}.lock"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\"", [mark], privileged: true)?
    let _ = testing.remote_text(host, "delgroup \"$1\" >/dev/null 2>&1 || true", [name], privileged: true)?
    let deploy = write_deploy(dir, group_body(name, mark, direction))?
    let cancelled = apply_cancelled_at_gate(dir, inventory, host, deploy, lock_path, mark, boundary_signal(direction))?
    assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stderr}"
    assert_entry_status(cancelled, "gate", "command", "unknown")
    if direction == "before" {
      assert_entry_status(cancelled, "target", "group", "blocked")
      assert testing.remote_text(host, "getent group \"$1\" || echo absent", [name])? == "absent\n"
    } else {
      assert_entry_status(cancelled, "target", "group", "changed")
      assert name in testing.remote_text(host, "getent group \"$1\"", [name])?
    }
    assert_lock_free(host, lock_path)?
    let again = apply_again(dir, inventory, host, deploy, lock_path)?
    assert again.code == 0, again.stderr
    if direction == "before" {
      assert rerun_status(again, "target") == "changed"
    } else {
      assert rerun_status(again, "target") == "unchanged"
    }
    assert name in testing.remote_text(host, "getent group \"$1\"", [name])?
    let _ = testing.remote_text(host, "delgroup \"$1\" >/dev/null 2>&1 || true", [name], privileged: true)?
  }
}

proc user_body(name: Str, mark: Str, direction: Str) -> Str {
  if direction == "before" {
    [
      gate_decl(mark, []),
      f"    declare.user_account(id: \"target\", name: \"{name}\", uid: 4322, primary_group: \"wheel\", groups: [\"wheel\"], home: \"/home/{name}\", shell: \"/bin/ash\", needs: [\"gate\"])?,",
    ].join("\n")
  } else {
    [
      f"    declare.user_account(id: \"target\", name: \"{name}\", uid: 4322, primary_group: \"wheel\", groups: [\"wheel\"], home: \"/home/{name}\", shell: \"/bin/ash\")?,",
      gate_decl(mark, ["target"]),
    ].join("\n")
  }
}

test cancellation_before_and_after_a_user_is_reported_from_the_target_side_and_converges { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  let token = testing.scratch_name(dir).replace("-", with: "")
  let name = f"xu{token.byte_slice(0, 10)}"
  for direction in ["before", "after"] {
    let base = f"/var/tmp/{testing.scratch_name(dir)}-user-{direction}"
    let mark = f"{base}.mark"
    let lock_path = f"{base}.lock"
    let _ = testing.remote_text(host, "rm -rf -- \"$1\"", [mark], privileged: true)?
    let _ = testing.remote_text(host, "deluser \"$1\" >/dev/null 2>&1 || true", [name], privileged: true)?
    let deploy = write_deploy(dir, user_body(name, mark, direction))?
    let cancelled = apply_cancelled_at_gate(dir, inventory, host, deploy, lock_path, mark, boundary_signal(direction))?
    assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stderr}"
    assert_entry_status(cancelled, "gate", "command", "unknown")
    if direction == "before" {
      assert_entry_status(cancelled, "target", "user", "blocked")
      assert testing.remote_text(host, "id -u \"$1\" 2>/dev/null || echo absent", [name])? == "absent\n"
    } else {
      assert_entry_status(cancelled, "target", "user", "changed")
      assert testing.remote_text(host, "id -u \"$1\"", [name])? == "4322\n"
    }
    assert_lock_free(host, lock_path)?
    let again = apply_again(dir, inventory, host, deploy, lock_path)?
    assert again.code == 0, again.stderr
    if direction == "before" {
      assert rerun_status(again, "target") == "changed"
    } else {
      assert rerun_status(again, "target") == "unchanged"
    }
    assert testing.remote_text(host, "id -u \"$1\"", [name])? == "4322\n"
    let _ = testing.remote_text(host, "deluser \"$1\" >/dev/null 2>&1 || true", [name], privileged: true)?
  }
}

proc service_cleanup(host: model.Host, name: Str) [env, process, error] -> Result[Unit, Error] {
  let _ = testing.remote_text(host, "rc-service \"$1\" stop >/dev/null 2>&1 || true; rc-update del \"$1\" default >/dev/null 2>&1 || true; rm -f \"/etc/init.d/$1\" \"/var/tmp/$1\".*", [name], privileged: true)?
}

proc service_body(name: Str, script: Str, mark: Str, direction: Str) -> Str {
  let init_line = f"    declare.file(id: \"init\", at: \"/etc/init.d/{name}\", text: r\"\"\"{script}\"\"\", mode: 0o755)?,"
  if direction == "before" {
    [
      init_line,
      gate_decl(mark, ["init"]),
      f"    declare.service(id: \"target\", name: \"{name}\", enabled: true, running: true, needs: [\"init\", \"gate\"])?,",
    ].join("\n")
  } else {
    [
      init_line,
      f"    declare.service(id: \"target\", name: \"{name}\", enabled: true, running: true, needs: [\"init\"])?,",
      gate_decl(mark, ["target"]),
    ].join("\n")
  }
}

proc service_notify_body(name: Str, value: Str, script: Str, mark: Str) -> Str {
  let init_line = f"    declare.file(id: \"init\", at: \"/etc/init.d/{name}\", text: r\"\"\"{script}\"\"\", mode: 0o755)?,"
  let conf_line = f"    declare.file(id: \"conf\", at: \"/var/tmp/{name}.conf\", text: \"{value}\\n\", needs: [\"init\"])?,"
  [
    init_line,
    conf_line,
    f"    declare.service(id: \"target\", name: \"{name}\", enabled: true, running: true, reload_on: [\"conf\"], needs: [\"init\"])?,",
  ].join("\n")
}

test cancellation_before_and_after_a_service_is_reported_from_the_target_side_and_converges { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  let token = testing.scratch_name(dir).replace("-", with: "")
  let name = f"xs{token.byte_slice(0, 10)}"
  for direction in ["before", "after"] {
    let base = f"/var/tmp/{testing.scratch_name(dir)}-service-{direction}"
    let mark = f"{base}.mark"
    let lock_path = f"{base}.lock"
    service_cleanup(host, name)?
    let _ = testing.remote_text(host, "rm -rf -- \"$1\"", [mark], privileged: true)?
    let deploy = write_deploy(dir, service_body(name, quick_service_script, mark, direction))?
    let cancelled = apply_cancelled_at_gate(dir, inventory, host, deploy, lock_path, mark, boundary_signal(direction))?
    assert cancelled.code == 3, f"the cancelled apply exited {cancelled.code}: {cancelled.stderr}"
    assert_entry_status(cancelled, "gate", "command", "unknown")
    if direction == "before" {
      assert_entry_status(cancelled, "target", "service", "blocked")
      let levels = testing.remote_text(host, "ls /etc/runlevels/default", [], privileged: true)?
      assert name not in levels
    } else {
      assert_entry_status(cancelled, "target", "service", "changed")
      assert "started" in testing.remote_text(host, "rc-service \"$1\" status 2>&1 || true", [name], privileged: true)?
      assert name in testing.remote_text(host, "ls /etc/runlevels/default", [], privileged: true)?
    }
    assert_lock_free(host, lock_path)?
    let again = apply_again(dir, inventory, host, deploy, lock_path)?
    assert again.code == 0, again.stderr
    if direction == "before" {
      assert rerun_status(again, "target") == "changed"
    } else {
      assert rerun_status(again, "target") == "unchanged"
    }
    assert "started" in testing.remote_text(host, "rc-service \"$1\" status 2>&1 || true", [name], privileged: true)?
    service_cleanup(host, name)?
  }
}

test an_in_flight_service_notification_cancellation_is_unknown_and_converges { |ctx|
  guard let host = testing.fixture_host("fx-3")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let inventory = inventory()?
  let token = testing.scratch_name(dir).replace("-", with: "")
  let name = f"xi{token.byte_slice(0, 10)}"
  service_cleanup(host, name)?
  let lock_path = f"/var/tmp/{testing.scratch_name(dir)}-inflight-service.lock"
  let first_deploy = write_deploy(dir, service_notify_body(name, "1", notify_service_script, f"/var/tmp/{name}.mark"))?
  let first = apply_again(dir, inventory, host, first_deploy, lock_path)?
  assert first.code == 0, first.stderr
  assert "started" in testing.remote_text(host, "rc-service \"$1\" status 2>&1 || true", [name], privileged: true)?
  let deploy = write_deploy(dir, service_notify_body(name, "2", notify_service_script, f"/var/tmp/{name}.mark"))?
  let cancelled = cancelled_inflight(
    dir,
    inventory,
    host,
    deploy,
    lock_path,
    "test -e \"$1\" && echo yes || echo no",
    [f"/var/tmp/{name}.reloading"],
    "TERM",
  )?
  assert_cancelled(cancelled, "target", "service")
  assert "started" in testing.remote_text(host, "rc-service \"$1\" status 2>&1 || true", [name], privileged: true)?
  assert testing.remote_text(host, "cat \"$1\"", [f"/var/tmp/{name}.conf"], privileged: true)? == "2\n"
  assert_lock_free(host, lock_path)?
  let again = apply_again(dir, inventory, host, deploy, lock_path)?
  assert again.code == 0, again.stderr
  assert "started" in testing.remote_text(host, "rc-service \"$1\" status 2>&1 || true", [name], privileged: true)?
  service_cleanup(host, name)?
}
