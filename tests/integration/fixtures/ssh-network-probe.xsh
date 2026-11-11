##! Native SSH client for the maintained-guest network-recovery drill. Each
##! operation opens one fresh session to the DHCP-assigned address, verifies the
##! pinned host key, and runs one fixed guest command. The host test owns the
##! keys and decides when a connection should succeed or fail.
proc main(...argv: List[Str]) [fs, process, net, env, time, error, io] {
  let host = argv[0]
  let port = argv[1].parse_int()?
  let key = Path(argv[2])
  let host_key = argv[3]
  let operation = argv[4]
  let argument = if argv.len() > 5 { argv[5] } else { "" }
  let command = match operation {
    "probe" => "print \"ssh-probe-ok\"",
    "info" => "",
    "read" => f"print p\"{argument}\".read_text()?.trim()",
    "status" => "let out = p\"/home/probe/ssh-status.out\"; let err = p\"/home/probe/ssh-status.err\"; let s = process.run(process.command_argv(p\"/usr/bin/xinit\", [\"xinit\", \"status\", \"dhcp-eth0\"], p\"/home/probe\", {}, b\"\", out, err, timeout: 15s))?; assert s.ok; print out.read_text()?.trim()",
    else => { fail "unknown probe operation" },
  }
  with session = ssh.connect({host: host, port: port, user: "probe", key: key, host_key: host_key, timeout_ms: 6000})? {
    let info = ssh.info(session)?
    if info.host_key != host_key {
      fail f"host key {info.host_key} differs from the pinned {host_key}"
    }
    if operation == "info" {
      print $info.host_key
    } else {
      let result = ssh.exec(session, command, {timeout_ms: 20000})?
      if result.exit_code != 0 or result.missing {
        fail "remote command failed: " + (result.stderr.utf8() ?? "")
      }
      io.write_stdout_bytes(result.stdout)?
    }
  }
}
main(@args)?
