use packages.oxish.service as oxish_service

proc main(...argv: List[Str]) {
  let mode = argv[0]
  let binary = fp"{argv[1]}"
  let port = (e"XINIT_OXISH_PORT" ?? "0").parse_int()?
  let host_key = fp"{e"XINIT_OXISH_HOST_KEY" ?? ""}"
  let accounts = fp"{e"XINIT_OXISH_ACCOUNTS" ?? ""}"
  let child = unix.spawn_process_group(process.command_argv(binary, oxish_service.oxish_argv(bind: "127.0.0.1", port: port, host_key:, accounts:)))?
  defer {
    let cleanup = unix.shutdown_process_groups([child.pid], 100ms, 100ms)?
    assert cleanup.remaining.is_empty()
  }
  if mode == "positive" {
    wait until oxish_service.ready() within 5s every 20ms
    print "PASS owned oxish-server listener became ready"
  } else {
    assert ! oxish_service.ready()?
    print "PASS foreign listener did not make oxish-server ready"
  }
}
