##! Native SSH client for the disposable activation reply-loss drill.
proc main(...argv: List[Str]) [fs, process, net, env, time, error, io] {
  let port = argv[0].parse_int()?
  let key = Path(argv[1])
  let host_key = argv[2]
  let operation = argv[3]
  let source = if argv.len() > 4 { Path(argv[4]) } else { p"" }
  let root = "/home/probe/ssh-proof"
  let command = match operation {
    "probe" => "io.write_stdout_bytes(io.stdin_bytes()?)?; exit 7",
    "home-write" => "let f = p\"/home/probe/ssh-home-proof\"; f.write(\"ok\")?; assert f.read_text()? == \"ok\"; let info = p\"/etc\".metadata()?; assert info.uid == 0 and info.gid == 0; print \"home-ok\"",
    "setup" => f"assert \"LAPUTA_ACTIVATION_SSH_FIXTURE=1\" in p\"/proc/cmdline\".read_text()?.trim().split(\" \" ); let r = json.read(p\"/run/laputa-running-generation.json\")?.require(Record)?; assert r.get(\"profile\")?.require(Str)? == \"qemu-maintained\"; p\"{root}/system\".mkdir(parents: true)?",
    "activation" => f"p\"{root}/system/activation.xsh\".write(io.stdin_bytes()?)?",
    "launcher" => f"p\"{root}/system/launcher.xsh\".write(io.stdin_bytes()?)?",
    "fixture" => f"p\"{root}/activation-ssh-guest.xsh\".write(io.stdin_bytes()?)?",
    "poll" => f"print p\"{root}/committed\".exists()?",
    "release" => f"p\"{root}/release\".write(\"\")?",
    "reaped" => f"let pid = p\"{root}/committed\".read_text()?; let gone = !fp\"/proc/{{pid}}\".exists()?; print $gone",
    "prepare" | "stage" | "inspect" => f"let s = process.run(process.command_argv(/usr/bin/xsh, [\"/usr/bin/xsh\", \"{root}/activation-ssh-guest.xsh\", \"--\", \"{operation}\", \"{root}\"], /home/probe, {{XSH_MODULE_PATH: \"{root}\"}}))?; exit s.exit_code()?",
    _ => { fail "unknown SSH drill operation" },
  }
  let input = if operation == "probe" { b"ssh-stdin\n" } else if source == p"" { b"" } else { source.read_bytes()? }
  with session = ssh.connect({host: "127.0.0.1", port: port, user: "probe", key: key, host_key: host_key, timeout_ms: 5000})? {
    let result = ssh.exec(session, command, {stdin: input, timeout_ms: 60000})?
    if operation == "probe" {
      assert result.exit_code == 7 and !result.missing and result.stdout == input
    } else if result.exit_code != 0 or result.missing {
      fail "remote command failed: " + (result.stderr.utf8() ?? "")
    }
    io.write_stdout_bytes(result.stdout)?
  }
}
main(@args)?
