##! Black-box behavior of the fixed remote administration program: the exact text that
##! is sent over SSH runs here as a script with a request on stdin.
const protocol = "laputa-remote-1"
const zeros = "0000000000000000000000000000000000000000000000000000000000000000"

proc ask(ctx: TestContext, home: Path, request: Str, payload: Bytes = bytes.from_text("")) -> Result[Record] {
  let program = p"system/remote_guest.xsh".resolve()?
  let input = fp"{home}/request.bin"
  input.write(bytes.concat([bytes.from_text(request + "\n"), payload]))?
  let output = fp"{home}/reply.json"
  let status = process.run(process.command_argv(
    ctx.xsh_bin,
    [ctx.xsh_bin.display(), program.display()],
    stdin: input,
    stdout: output,
    env: {HOME: home.display()},
    timeout: 20s,
  ))?
  guard status.ok else { fail "the remote program must always answer with exit status zero" }
  json.read(output)?.require(Record)?
}

proc header(op: Str, fields: Str = "") -> Str {
  f"{{\"protocol\":\"{protocol}\",\"op\":\"{op}\"{fields}}}"
}

proc staged(ctx: TestContext, home: Path, name: Str, content: Bytes, declared_size: Int, declared_digest: Str) -> Result[Record] {
  let fields = f",\"name\":\"{name}\",\"size\":{declared_size},\"sha256\":\"{declared_digest}\""
  ask(ctx, home, header("stage", fields), content)?
}

test remote_program_answers_unknown_operations_and_other_protocols { |ctx|
  let home = test.temp_dir(ctx, name: "home")?
  let unknown = ask(ctx, home, header("reboot"))?
  assert unknown.ok == false
  assert json.get(unknown, ["error", "message"], "").require(Str)? == "unknown operation reboot"
  let other = ask(ctx, home, "{\"protocol\":\"laputa-remote-2\",\"op\":\"inspect\"}")?
  assert other.ok == false
  let pad = bytes.zero(5000)?.base64()
  let oversized = ask(ctx, home, "{\"protocol\":\"laputa-remote-1\",\"op\":\"inspect\",\"pad\":\"" + pad + "\"}")?
  assert oversized.ok == false
}

test remote_program_runs_an_argv_without_a_shell { |ctx|
  let home = test.temp_dir(ctx, name: "home")?
  let ran = ask(ctx, home, header("run", ",\"argv\":[\"/bin/echo\",\"a b;$HOME\"],\"timeout_ms\":5000"))?
  assert ran.ok == true
  let encoded = json.get(ran, ["result", "stdout_b64"], "").require(Str)?
  assert encoded.base64_decode()?.utf8()? == "a b;$HOME\n"
  let empty = ask(ctx, home, header("run", ",\"argv\":[]"))?
  assert empty.ok == false
  let slow = ask(ctx, home, header("run", ",\"argv\":[\"/bin/echo\"],\"timeout_ms\":99999999"))?
  assert slow.ok == false
}

test remote_program_stages_a_verified_file_once { |ctx|
  let home = test.temp_dir(ctx, name: "home")?
  let content = bytes.from_text("candidate bytes")
  let digest = content.sha256().hex()
  let first = staged(ctx, home, "candidate.bin", content, content.len(), digest)?
  assert first.ok == true
  assert json.get(first, ["result", "outcome"], "").require(Str)? == "staged"
  assert fp"{home}/staging/candidate.bin".read_bytes()? == content
  let again = staged(ctx, home, "candidate.bin", content, content.len(), digest)?
  assert json.get(again, ["result", "outcome"], "").require(Str)? == "present"
  let other = bytes.from_text("different bytes")
  let conflict = staged(ctx, home, "candidate.bin", other, other.len(), other.sha256().hex())?
  assert conflict.ok == false
  assert fp"{home}/staging/candidate.bin".read_bytes()? == content
}

test remote_program_leaves_no_file_after_a_refused_transfer { |ctx|
  let home = test.temp_dir(ctx, name: "home")?
  let content = bytes.from_text("candidate bytes")
  let digest = content.sha256().hex()
  let wrong_digest = staged(ctx, home, "a.bin", content, content.len(), zeros)?
  assert wrong_digest.ok == false
  let short = staged(ctx, home, "b.bin", content, content.len() + 5, digest)?
  assert short.ok == false
  let long = staged(ctx, home, "c.bin", bytes.concat([content, bytes.from_text("extra")]), content.len(), digest)?
  assert long.ok == false
  let escaping = staged(ctx, home, "../escape", content, content.len(), digest)?
  assert escaping.ok == false
  let hidden = staged(ctx, home, ".incoming-x", content, content.len(), digest)?
  assert hidden.ok == false
  let leftovers = fs.children(fp"{home}/staging")?.collect()
  assert leftovers.is_empty()
  assert ! fp"{home}/escape".exists()?
}
