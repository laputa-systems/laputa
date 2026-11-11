use infra.model
use infra.scripts
use infra.testing
use infra.transport

const hostile = ["plain", "", "-x", "--", "it's", "a b", "line\nbreak", "$HOME", "$(echo injected)", "`id`", "; id", "*", "\\", "caf\u{e9}", "tab\there"]

test the_remote_login_shell_preserves_hostile_arguments {
  guard let host = testing.fixture_host("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let connection = transport.connect(host)?
  let result = transport.exec(connection, scripts.echo_arguments, hostile)?
  assert result.code == 0
  let expected = hostile |> map { |word| word + "\0" } |> collect()
  assert result.stdout.utf8()? == expected.join("")
}

test doas_runs_a_script_as_root_and_a_plain_user_is_refused {
  guard let host = testing.fixture_host("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let connection = transport.connect(host)?
  let plain = transport.exec(connection, "id -u")?
  assert plain.stdout.utf8()?.trim() == "1000"
  let root = transport.exec(connection, "id -u", privileged: true)?
  assert root.stdout.utf8()?.trim() == "0"

  guard let denied_host = testing.fixture_host("fx-1-plain")? else {
    return
  }

  let denied = transport.connect(denied_host)?
  let refused = transport.exec(denied, "id -u", privileged: true)?
  assert refused.code != 0
  assert "doas" in refused.stderr.utf8()?
}

test a_wrong_host_key_pin_fails_before_any_command {
  guard let host = testing.fixture_host("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let wrong: model.Host = {...host, host_key: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
  match transport.connect(wrong) {
    Err(transport.TransportError.Unreachable {message}) => assert "mismatch" in message
    else => assert false, "a wrong pin did not fail the connection"
  }
}

test a_remote_failure_status_is_data_and_stdin_is_binary_safe {
  guard let host = testing.fixture_host("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let connection = transport.connect(host)?
  let failed = transport.exec(connection, "exit 9")?
  assert failed.code == 9
  let payload = b"\x00\x01binary\xff\n"
  let echoed = transport.exec(connection, "cat", stdin: payload)?
  assert echoed.stdout == payload
}

test a_transfer_larger_than_the_capture_limit_streams_in_and_out_intact { |ctx|
  guard let host = testing.fixture_host("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let dir = test.temp_dir(ctx)?
  let blob = fp"{dir}/blob"
  run dd if=/dev/urandom of=$blob bs=1M count=24 status=none
  let local = hash.sha256(blob)?
  let connection = transport.connect(host)?
  let remote = transport.exec(connection, "sha256sum", stdin_path: blob, timeout_ms: 60000)?
  assert remote.stdout.utf8()?.fields()[0] == local.hex()
}

test a_timed_out_command_is_interrupted_and_leaves_the_session_unusable {
  guard let host = testing.fixture_host("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  let connection = transport.connect(host)?
  assert transport.usable(connection)
  match transport.exec(connection, "sleep 5", timeout_ms: 300) {
    Err(transport.TransportError.Interrupted {..}) => assert true
    else => assert false, "a timeout after submission was not interrupted"
  }

  assert ! transport.usable(connection)
  match transport.exec(connection, "true") {
    Err(transport.TransportError.NotSubmitted {..}) => assert true
    else => assert false, "a dead session accepted a request"
  }
}

test connect_all_opens_reachable_hosts_in_parallel_and_fails_only_the_unreachable_one {
  guard let first = testing.fixture_host("fx-1")? else {
    test.skip("fixture environment is absent")
    return
  }

  guard let second = testing.fixture_host("fx-2")? else {
    return
  }

  let unreachable: model.Host = {...first, name: "nowhere", address: "127.0.0.1", port: 1, timeout_ms: 2000}
  let opened = transport.connect_all([first, unreachable, second], 3)
  assert opened.len() == 3
  assert opened[0] is Ok(_)
  assert opened[1] is Err(transport.TransportError.Unreachable {..})
  assert opened[2] is Ok(_)
  match opened[2] {
    Ok(connection) => assert transport.exec(connection, "true")?.code == 0
    Err(_) => assert false, "the second host did not open"
  }
}
