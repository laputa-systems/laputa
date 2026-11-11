use infra.scripts
use infra.shell
use infra.testing
use infra.transport

const hostile = ["plain", "", "-x", "--", "it's", "a b", "line\nbreak", "$HOME", "$(echo injected)", "`id`", "; id", "*", "\\", "caf\u{e9}"]

proc local() [process, error] -> Result[transport.Connection, transport.TransportError] {
  transport.connect(testing.local_host())
}

test hostile_arguments_arrive_byte_for_byte {
  let connection = local()?
  let result = transport.exec(connection, scripts.echo_arguments, hostile)?
  assert result.code == 0
  let expected = hostile |> map { |word| word + "\0" } |> collect()
  assert result.stdout.utf8()? == expected.join("")
}

test a_nonzero_exit_is_an_execution_not_an_error {
  let connection = local()?
  let result = transport.exec(connection, "printf out; printf err >&2; exit 7")?
  assert result.code == 7
  assert result.stdout == b"out"
  assert result.stderr == b"err"
}

test stdin_bytes_and_files_reach_the_script_unchanged {
  let connection = local()?
  let payload = b"\x00\x01binary\xff\n"
  let echoed = transport.exec(connection, "cat", stdin: payload)?
  assert echoed.stdout == payload

  let scratch = fs.tempdir()?
  let source = fp"{scratch.host_path()?}/blob"
  source.write(payload)
  let streamed = transport.exec(connection, "cat", stdin_path: source)?
  assert streamed.stdout == payload
}

test a_command_killed_by_a_signal_is_abnormal_not_exit_zero {
  let connection = local()?
  match transport.exec(connection, "kill -TERM $$") {
    Err(transport.TransportError.Abnormal {message}) => assert "signal" in message
    else => assert false, "a signal death was not abnormal"
  }
}

test a_timeout_after_the_command_started_is_interrupted {
  let connection = local()?
  match transport.exec(connection, "sleep 5", timeout_ms: 200) {
    Err(transport.TransportError.Interrupted {..}) => assert true
    else => assert false, "a timeout was not interrupted"
  }
}

test a_nul_in_an_argument_is_refused_before_anything_runs {
  let connection = local()?
  match transport.exec(connection, "true", ["a\0b"]) {
    Err(transport.TransportError.Refused {..}) => assert true
    else => assert false, "NUL was not refused"
  }
}

test certainty_is_read_from_the_typed_error_of_the_native_client {
  match ssh.connect({}) {
    Err(error) => assert transport.certainty_of(error) == .NotSubmitted
    Ok(_) => assert false, "an empty option record connected"
  }
}

test connect_all_answers_every_host_in_order_and_a_local_host_needs_no_session {
  let hosts = [testing.local_host("a"), testing.local_host("b")]
  let opened = transport.connect_all(hosts, 4)
  assert opened.len() == 2
  assert opened[0] is Ok(_)
  assert opened[1] is Ok(_)
}

test escalation_prefixes_the_whole_command_with_noninteractive_doas {
  let plain = shell.command("true", ["a"])?
  let escalated = shell.escalated_command("true", ["a"])?
  assert escalated == f"doas -n {plain}"
  assert plain.starts_with("/bin/sh -c ")
}

test the_login_shell_sees_one_word_per_argument {
  let command = shell.command("echo $1", ["a b; id"])?
  assert command == "/bin/sh -c 'echo $1' xinfra 'a b; id'"
  assert shell.quote("a\0b") is Err(_)
}
