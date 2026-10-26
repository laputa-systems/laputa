proc main(expected: Str, host_sentinel: Path) [fs, process, net, env, error] {
  assert (e"LAPUTA_AMBIENT_POISON" ?? "") == ""
  assert (e"HTTP_PROXY" ?? "") != "http://laputa-poison.invalid:9"
  assert (e"HTTPS_PROXY" ?? "") != "http://laputa-poison.invalid:9"
  assert ! host_sentinel.exists()?
  let mounted_sentinel = /src/laputa/mounted-sentinel
  match mounted_sentinel.write("poison") {
    Ok(_) => fail "read-only checkout allowed a write"
    Err(_) => {}
  }
  let constants = linux.net_constants()
  let socket = linux.socket(constants.AF_INET, constants.SOCK_DGRAM)?
  defer unix.close_fd(socket)
  match linux.connect(socket, {family: "inet", address: "192.0.2.1", port: 9}) {
    Ok(_) => assert expected == "reachable"
    Err(failure) => {
      assert expected == "isolated"
      assert failure.errno == 101
    }
  }
  let output = /output/offline-result
  output.write("declared offline operation passed\n")
  assert output.read_text()? == "declared offline operation passed\n"
  print f"network {expected}; poison absent; declared output passed"
}
