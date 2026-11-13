use pm.remote

test test_concurrent_immutable_file_publication [fs, process, env, time, net, error] { |ctx|
  let root = test.temp_dir(ctx, name: "atomic-remote")?
  let script = fp"{root}/worker.xsh"
  script.write("""use pm.remote
proc main(...argv: List[Str]) [fs, net, time, error] {
  fp"{argv[2]}".write("ready")
  wait until fp"{argv[3]}".exists() within 10s every 10ms
  let _ = remote.upload_immutable_repo_file(argv[0], p"objects/key", fp"{argv[1]}", "", fp"{argv[4]}")?
}
main(@args)?
""")
  let a = fp"{root}/a"
  let b = fp"{root}/b"
  a.write("first")
  b.write("second")
  let ready_a = fp"{root}/ready-a"
  let ready_b = fp"{root}/ready-b"
  let release = fp"{root}/release"
  let url = f"file://{root}/remote"
  let other_stage = fp"{root}/remote/objects/.key.tmp"
  other_stage.parent.mkdir()
  other_stage.write("other publisher staging")
  let configured = e"XSH_HOST" ?? ""
  let runner = if configured != "" { fp"{configured}" } else { process.which("xsh")? }
  let first = spawn run $runner $script $url $a $ready_a $release $root ?
  let second = spawn run $runner $script $url $b $ready_b $release $root ?
  wait until ready_a.exists()? and ready_b.exists()? within 10s every 10ms
  release.write("go")
  let statuses = wait [first, second]?
  assert statuses[0].ok != statuses[1].ok
  let dest = fp"{root}/remote/objects/key"
  let winner = if statuses[0].ok { a } else { b }
  assert dest.read_bytes()? == winner.read_bytes()?
  assert other_stage.read_text()? == "other publisher staging"
  assert remote.upload_immutable_repo_file(url, p"objects/key", winner, "", root)? == false
  assert dest.read_bytes()? == winner.read_bytes()?
}
