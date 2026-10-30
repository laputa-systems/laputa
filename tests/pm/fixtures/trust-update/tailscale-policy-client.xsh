error ClientError = Failed(message: Str)

proc wait_for_socket(socket: Path) [fs, time, error] {
  var attempts = 0
  while attempts < 100 {
    return when socket.exists()?
    time.sleep(100ms)?
    attempts += 1
  }
  return Err(ClientError.Failed("daemon socket did not appear"))
}

proc stop_daemon(handle: ProcessHandle) [process, error] {
  handle.cancel(signal: "TERM", kill_after: 5s)
}

proc run_client(port: Int, root: Str, expected: Str) [fs, process, time, error] {
  let log = p"/work/daemon.log"
  let socket = p"/work/daemon.sock"
  let child_env = {SSL_CERT_FILE: f"/fixtures/tls/{root}.crt", HOME: "/work", PATH: "/usr/bin:/bin"}
  let daemon = process.command_argv(
    /package/usr/bin/tailscaled,
    ["/package/usr/bin/tailscaled", "--tun=userspace-networking", "--state=/work/state", "--socket=/work/daemon.sock", "--no-logs-no-support", "--port=0"],
    /work,
    child_env,
    stdout: log,
    stderr: log,
  )
  let launched = spawn daemon ?
  defer stop_daemon(launched)
  wait_for_socket(socket)?
  let up = process.command_argv(
    /package/usr/bin/tailscale,
    ["/package/usr/bin/tailscale", "--socket=/work/daemon.sock", "up", f"--login-server=https://127.0.0.1:{port}", "--timeout=3s"],
    /work,
    child_env,
    timeout: 20s,
  )
  let _ = process.run(up)?
  time.sleep(500ms)?
  let text = log.read_text()?
  if expected not in text {
    return Err(ClientError.Failed(f"expected {expected} in daemon output: {text}"))
  }
}

run_client(args[0].parse_int_decimal()?, args[1], args[2])?
