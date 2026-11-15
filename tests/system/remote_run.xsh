use system.remote

proc guest(ctx: TestContext, request: Record) [fs, process, error] -> Result[Record, Error] {
  let source = p"system/remote_guest.xsh".read_text()?
  let result = test.run_script(ctx, source, env: {REMOTE_INHERITED: "inherited"}, stdin: bytes.from_text(json.encode(request)? + "\n"))?
  assert result.status == 0, result.stderr
  json.decode(result.stdout)?.require(Record)?
}

proc stdout_text(reply: Record) [error] -> Result[Str, Error] {
  json.get(reply, ["result", "stdout_b64"], "").require(Str)?.base64_decode()?.utf8()?
}

test test_run_scoped_overlays_the_environment_and_sets_the_directory [fs, process, error] { |ctx|
  let overlay: Map[Str] = {REMOTE_OVERLAY: "present"}
  let env_reply = guest(ctx, remote.remote_run_request(["/usr/bin/env"], 30000, overlay, null))?
  assert json.get(env_reply, ["ok"], false) == true
  let output = stdout_text(env_reply)?
  assert "REMOTE_INHERITED=inherited" in output
  assert "REMOTE_OVERLAY=present" in output

  let pwd_reply = guest(ctx, remote.remote_run_request(["/bin/pwd"], 30000, null, "/"))?
  assert stdout_text(pwd_reply)? == "/\n"
}

test test_plain_run_ignores_scoped_fields [fs, process, error] { |ctx|
  let reply = guest(ctx, {protocol: "laputa-remote-1", op: "run", argv: ["/usr/bin/env"], timeout_ms: 30000, env: {REMOTE_OVERLAY: "present"}, cwd: "relative"})?
  assert json.get(reply, ["ok"], false) == true
  assert ! ("REMOTE_OVERLAY=present" in stdout_text(reply)?)
}

test test_run_scoped_rejects_invalid_options [fs, process, error] { |ctx|
  for name in ["", "BAD=NAME", "BAD\u{0}NAME"] {
    let empty: Map[Str] = {}
    let reply = guest(ctx, remote.remote_run_request(["/bin/true"], 30000, empty.set(name, "value"), null))?
    assert json.get(reply, ["ok"], true) == false
    assert json.get(reply, ["error", "kind"], "") == "env"
  }
  for dir in ["relative", "/this-directory-does-not-exist-laputa-remote"] {
    let reply = guest(ctx, remote.remote_run_request(["/bin/true"], 30000, null, dir))?
    assert json.get(reply, ["ok"], true) == false
    assert json.get(reply, ["error", "kind"], "") == "cwd"
  }
}

test test_an_unknown_operation_is_refused_without_running [fs, process, error] { |ctx|
  let marker = fp"{test.temp_dir(ctx, name: "remote-unknown-op")?}/ran"
  let reply = guest(ctx, {protocol: "laputa-remote-1", op: "run-unsupported", argv: ["/bin/touch", marker.display()], timeout_ms: 30000})?
  assert json.get(reply, ["ok"], true) == false
  assert ! marker.exists()?
}

test test_requests_without_options_keep_the_run_operation {
  let plain = remote.remote_run_request(["/bin/true"], 30000, null, null)
  assert json.get(plain, ["op"], "") == "run"
  assert ! ("env" in plain.keys()) and ! ("cwd" in plain.keys())
  assert json.get(remote.remote_run_request(["/bin/true"], 30000, null, "/"), ["op"], "") == "run-scoped"
  let overlay: Map[Str] = {A: "1"}
  assert json.get(remote.remote_run_request(["/bin/true"], 30000, overlay, null), ["op"], "") == "run-scoped"
}
