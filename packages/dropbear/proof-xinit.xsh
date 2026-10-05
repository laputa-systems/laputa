##! XSH module `proof-xinit` package and build operations.
error ScriptError = Failed(kind: Str, message: Str)

proc ensure(condition: Bool, kind: Str, message: Str) {
  if ! condition {
    Err(ScriptError.Failed(kind:, message:))?
  }
}

proc public_key_line(body: Str) [error] -> Result[Str] {
  for line in body.lines() {
    let trimmed = line.trim()

    return trimmed when trimmed.starts_with("ssh-")
  }

  Err(ScriptError.Failed(kind: "dropbear-public-key", message: "dropbearkey did not print an SSH public key"))
}

proc authorize_root_key(rootfs: Path, public_key: Str) {
  let ssh_dir = fp"{rootfs}/root/.ssh"
  let auth_keys = fp"{ssh_dir}/authorized_keys"
  ssh_dir.mkdir()
  var existing = ""

  if auth_keys.exists() {
    existing = auth_keys.read_text()?
  }

  auth_keys.write(
    f"""{existing}{public_key}
""",
  )

  ssh_dir.chmod(0o700)
  auth_keys.chmod(0o600)
}

proc ensure_device(rootfs: Path, name: Str, major: Str, minor: Str) {
  let device_path = fp"{rootfs}/dev/{name}"

  return when device_path.exists()

  device_path.parent.mkdir()
  let mknod = process.which("mknod")?
  run $mknod "-m" "666" $device_path "c" $major $minor ?
}

pure dbclient_command(timeout_bin: Path, loader: Path, dbclient: Path, client_key: Path, port: Int) -> Command {
  let port_text = f"{port}"

  process.command_argv(
    timeout_bin,
    [
      timeout_bin,
      "1",
      loader,
      dbclient,
      "-N",
      "-y",
      "-i",
      client_key,
      "-p",
      port_text,
      "root@127.0.0.1",
    ],
  )
}

proc dropbear_auth_logged(rootfs: Path, chroot: Path) -> Bool {
  var logged = false

  if let Ok(body) = try run.text $chroot $rootfs "/usr/bin/xinit" logs dropbear {
    logged = "Pubkey auth succeeded" in body
  }

  logged
}

proc wait_for_ssh(command: Command, rootfs: Path, chroot: Path, port: Int, tries: Int) {
  var remaining = tries

  while remaining > 0 {
    let status = process.run(command)?

    return when status.ok or dropbear_auth_logged(rootfs, chroot)

    time.sleep(100ms)
    remaining -= 1
  }

  var status = ""
  var logs = ""

  match try run.text $chroot $rootfs "/usr/bin/xinit" status dropbear {
    Ok(body) => status = body.trim()
    Err(err) => status = f"status failed: {err.message}"
  }

  match try run.text $chroot $rootfs "/usr/bin/xinit" logs dropbear {
    Ok(body) => logs = body.trim()
    Err(err) => logs = f"logs failed: {err.message}"
  }

  return Err(
    ScriptError.Failed(
      kind: "dropbear-connect",
      message: f"dbclient could not connect before timeout; status={status}; logs={logs}; live={live_dropbear_diagnostics(port)?}",
    ),
  )
}

proc live_dropbear_diagnostics(port: Int) -> Result[Str] {
  let child_events = unix.reap_child_events()? |> map f"{.pid}:{status_summary(.status)}"

  let processes = process.list()?
    |> where "dropbear" in .argv
    |> map f"{.pid}:{.status}:{.argv}"

  let ports = process.port(port)? |> map f"{.pid}:{.protocol}:{.local}:{.state}:{.argv}"
  let default_ports = process.port(22)? |> map f"{.pid}:{.protocol}:{.local}:{.state}:{.argv}"

  f"events=[{child_events.join(" | ")}] processes=[{processes.join(" | ")}] ports=[{ports.join(" | ")}] default_ports=[{default_ports.join(" | ")}]"
}

pure status_summary(status: Status) -> Str {
  if status.exited() {
    if let Ok(code) = status.exit_code() {
      return f"exit:{code}"
    } else {
      return "exit:unknown"
    }
  }

  if status.signaled() {
    if let Ok(signal) = status.signal_number() {
      return f"signal:{signal}"
    } else {
      return "signal:unknown"
    }
  }

  status.kind
}

proc wait_for_xinit_logs(rootfs: Path, chroot: Path, tries: Int) -> Result[Str] {
  var remaining = tries

  while remaining > 0 {
    let result = try run.text $chroot $rootfs "/usr/bin/xinit" logs dropbear

    if let Ok(body) = result {
      guard body.trim() == "" else {
        return body
      }
    }

    time.sleep(100ms)
    remaining -= 1
  }

  Err(ScriptError.Failed(kind: "dropbear-log", message: "xinit did not write dropbear log content"))
}

proc xinit_start(rootfs: Path, chroot: Path, port: Int, host_key: Path) {
  env ({
    XINIT_DROPBEAR_BIND: "0.0.0.0",
    XINIT_DROPBEAR_PORT: f"{port}",
    XINIT_DROPBEAR_HOST_KEY: host_key.display(),
  }) {
    run $chroot $rootfs "/usr/bin/xinit" start dropbear ?
  }?
}

proc print_direct_dropbear_probe(rootfs: Path, chroot: Path, port: Int, label: Str, extra: List[Str]) {
  let probe = process.command_argv(
    chroot,
    [chroot.display(), rootfs.display(), "/usr/bin/dropbear", "-F", "-E", "-p", f"127.0.0.1:{port}"].extend(extra),
    timeout: 500ms,
  )

  match process.run(probe) {
    Ok(status) => print f"direct-dropbear-probe {label} {status_summary(status)}"
    Err(err) => print f"direct-dropbear-probe {label} error:{err.message}"
  }
}

proc main(rootfs = /rootfs, port = 22222) [fs, process, env, time, error] {
  let os = system.uname()?
  let dynlinker = fp"{rootfs}/usr/lib/ld-musl-{os.machine}.so.1"
  let dbclient = fp"{rootfs}/usr/bin/dbclient"
  let dropbearkey = fp"{rootfs}/usr/bin/dropbearkey"
  let log_dir = fp"{rootfs}/var/log/dropbear"
  let chroot = process.which("chroot")?
  let timeout_bin = process.which("timeout")?
  let tmp = /tmp/dropbear-proof-xinit
  tmp.mkdir()
  ensure(fp"{rootfs}/bin/xsh".exists()?, "xinit-control", "rootfs is missing /bin/xsh for service scripts")
  ensure(fp"{rootfs}/usr/bin/xinit".exists()?, "xinit-control", "rootfs is missing /usr/bin/xinit")
  ensure_device(rootfs, "null", "1", "3")
  ensure_device(rootfs, "random", "1", "8")
  ensure_device(rootfs, "urandom", "1", "9")
  fp"{rootfs}/tmp".mkdir()
  fp"{rootfs}/tmp".chmod(0o1777)
  log_dir.mkdir()
  fp"{log_dir}/current".remove(missing_ok: true)
  let host_key = fp"{rootfs}/tmp/dropbear_host_ed25519"
  let rsa_host_key = fp"{rootfs}/tmp/dropbear_host_rsa"
  let client_key = fp"{tmp}/dropbear_client_ed25519"
  host_key.remove(missing_ok: true)
  rsa_host_key.remove(missing_ok: true)
  run $dynlinker $dropbearkey "-t" "ed25519" "-f" $host_key ?
  run $dynlinker $dropbearkey "-t" "rsa" "-s" "2048" "-f" $rsa_host_key ?
  run $dynlinker $dropbearkey "-t" "ed25519" "-f" $client_key ?
  client_key.chmod(0o600)
  let public_key_text = run.text $dynlinker $dropbearkey "-y" "-f" $client_key ?
  let public_key = public_key_line(public_key_text)?
  authorize_root_key(rootfs, public_key)
  print_direct_dropbear_probe(rootfs, chroot, port + 1, "default-keys", [])
  print_direct_dropbear_probe(rootfs, chroot, port + 2, "ed25519", ["-r", "/tmp/dropbear_host_ed25519"])
  print_direct_dropbear_probe(rootfs, chroot, port + 3, "rsa", ["-r", "/tmp/dropbear_host_rsa"])
  xinit_start(rootfs, chroot, port, /tmp/dropbear_host_ed25519)
  let running = run.text $chroot $rootfs "/usr/bin/xinit" status dropbear ?

  ensure(
    "pid=0" not in running and "log=append" in running,
    "dropbear-start",
    f"xinit status did not report append logging for a running service: {running}",
  )

  let check = dbclient_command(timeout_bin, dynlinker, dbclient, client_key, port)
  wait_for_ssh(check, rootfs, chroot, port, 50)
  let log_text = wait_for_xinit_logs(rootfs, chroot, 50)?

  ensure(
    "Pubkey auth succeeded" in log_text,
    "dropbear-log",
    f"xinit log did not capture successful Dropbear auth: {log_text}",
  )

  print "xinit dropbear logs ok"
  run $chroot $rootfs "/usr/bin/xinit" stop dropbear ?
  let stopped_status = run.text $chroot $rootfs "/usr/bin/xinit" status dropbear ?
  ensure("pid=0" in stopped_status, "dropbear-stop", "xinit status still reported a service pid after stop")
  let listeners = process.port(port)? |> map .argv

  ensure(
    listeners.len() == 0,
    "dropbear-stop",
    f"dropbear still had listeners after stop: {live_dropbear_diagnostics(port)?}",
  )

  print "xinit dropbear ok"
}

main(@args)
