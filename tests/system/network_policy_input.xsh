use packages.laputa-net.network_plan as policy

type NetworkInputCommand = {code: Int, stdout: Str, stderr: Str}
type NetworkInputEntry = {script: Path, arguments: List[Str], fixture: Path, expected: Str}

pure entries() -> List[NetworkInputEntry] {
  [
    {script: p"packages/laputa-net/network_plan.xsh", arguments: [], fixture: p"tests/system/fixtures/network-policy-conflict.json", expected: "add address 192.0.2.3/24"},
    {script: p"tests/system/fixtures/network-policy-capture.xsh", arguments: ["replay"], fixture: p"tests/system/fixtures/network-policy-docker-conflict.json", expected: "desired address is foreign; ownership cannot be inferred"},
  ]
}

proc invoke(ctx: TestContext, entry: NetworkInputEntry, input: Path) [fs, process, error] -> Result[NetworkInputCommand, Error] {
  let root = test.temp_dir(ctx, name: entry.script.name)?
  let stdout = fp"{root}/stdout"
  let stderr = fp"{root}/stderr"
  let script = entry.script.resolve()?
  let argv = [ctx.xsh_bin.display(), script.display()] + entry.arguments + [input.display()]
  let status = process.run(process.command_argv(ctx.xsh_bin, argv, stdout: stdout, stderr: stderr, timeout: 5s))?
  Ok({code: status.shell_code()?, stdout: stdout.read_text()?, stderr: stderr.read_text()?})
}

test test_network_inputs_reject_oversize_before_decoding_invalid_utf8 [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "network-oversize")?
  let input = fp"{root}/oversize.json"
  input.write(bytes.concat([bytes.zero(66560)?, b"\xff"]))
  for entry in entries() {
    let result = invoke(ctx, entry, input)?
    assert result.code != 0
    assert "exceeds 65536 bytes" in result.stderr, result.stderr
  }
}

test test_network_inputs_accept_exactly_65536_valid_bytes [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "network-exact-limit")?
  var padding = " "
  while padding.byte_len() < 65536 { padding += padding }
  for entry in entries() {
    let body = entry.fixture.read_text()?
    let input = fp"{root}/{entry.script.name}.json"
    input.write(body + padding.byte_slice(0, 65536 - body.byte_len()))
    let result = invoke(ctx, entry, input)?
    assert result.code == 0, result.stderr
    assert entry.expected in result.stdout
  }
}

test test_network_input_read_failure_preserves_state_errno_and_kind [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "network-read-failure")?
  let directory = fp"{root}/directory"
  directory.mkdir()
  let rooted = fs.open_root(root)?
  let expected = rooted.read_result(p"directory", max_bytes: 65536)?
  assert expected.state != "observed"
  match policy.network_read_input(directory) {
    Err(policy.NetworkPolicyError.NetworkReadFailed {state, errno, error_kind, ..}) => {
      assert state == expected.state
      assert errno == expected.errno
      assert error_kind == expected.error_kind
    }
    Err(problem) => assert false, problem.message
    Ok(_) => assert false
  }
}
