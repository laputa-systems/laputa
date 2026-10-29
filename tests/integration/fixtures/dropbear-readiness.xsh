use packages.dropbear.service as dropbear_service

proc main(...argv: List[Str]) {
  let mode = argv[0]
  let binary = fp"{argv[1]}"
  let port = (e"XINIT_DROPBEAR_PORT" ?? "0").parse_int()?
  let child = unix.spawn_process_group(process.command_argv(binary, dropbear_service.dropbear_argv(bind: "127.0.0.1", port: port, ephemeral: (e"XINIT_DROPBEAR_EPHEMERAL" ?? "") == "1")))?
  defer {
    let cleanup = unix.shutdown_process_groups([child.pid], 100ms, 100ms)?
    assert cleanup.remaining.is_empty()
  }
  if mode == "positive" {
    wait until dropbear_service.ready() within 5s every 20ms
    print "PASS owned Dropbear listener became ready"
  } else {
    assert ! dropbear_service.ready()?
    print "PASS foreign listener did not make Dropbear ready"
  }
}
