#!/bin/xsh
use installer.host

error InstallerQemuTestError = Failed(kind: Str, message: Str)

proc env_int(name: Str, fallback: Int) -> Result[Int] {
  host.installer_env_value(name, f"{fallback}") as Int
}

proc command_path(name: Str) -> Result[Path] {
  return fp"{name}" when "/" in name

  process.which(name)?
}

proc ensure_dir(path_value: Path) {
  return when path_value.exists()

  path_value.mkdir()
}

proc ensure_file(path_value: Path, kind: Str) {
  return when path_value.exists()

  return Err(InstallerQemuTestError.Failed(kind:, message: f"missing {path_value}"))
}

proc process_live(kill: Path, pid: Int, cwd: Path) -> Result[Bool] {
  let status = process.run(process.command_argv(kill, ["kill", "-0", f"{pid}"], cwd, {}))?
  status.ok
}

proc terminate_if_live(pid: Int) {
  guard pid > 0 else {
    return
  }

  match process.kill(pid, signal: "TERM") {
    Ok(_) | Err(_) => {}
  }
}

proc dump_tail(tail: Path, log: Path, lines: Int) {
  guard log.exists() else {
    return
  }

  if let Ok(out) = try run.text $tail "-n" $lines $log {
    if out != "" {
      print $out
    }
  }
}

proc has_line_marker(log: Path, marker: Str) -> Result[Bool] {
  guard log.exists() else {
    return false
  }

  let body = log.read_text()?.replace("\r", "")

  for line in body.lines() {
    return true when line.trim() == marker
  }

  false
}

proc has_panic(log: Path) -> Result[Bool] {
  guard log.exists() else {
    return false
  }

  let body = log.read_text()?
  "Kernel panic" in body or "not syncing" in body or "Attempted to kill init" in body
}

proc wait_for_marker(
  pid: Int,
  kill: Path,
  tail: Path,
  log: Path,
  ok: Str,
  failed: Str,
  keep_running: Bool,
  timeout_seconds: Int,
  cwd: Path,
) {
  var elapsed = 0

  while process_live(kill, pid, cwd) {
    if has_line_marker(log, ok) {
      time.sleep(2s)

      if has_panic(log) {
        dump_tail(tail, log, 120)
        terminate_if_live(pid)
        return Err(InstallerQemuTestError.Failed(kind: "qemu", message: f"{ok} was followed by a kernel panic"))
      }

      return when keep_running

      terminate_if_live(pid)
      return
    }

    if has_line_marker(log, failed) or has_panic(log) {
      dump_tail(tail, log, 120)
      terminate_if_live(pid)
      return Err(InstallerQemuTestError.Failed(kind: "qemu", message: f"failed while waiting for {ok}"))
    }

    if elapsed >= timeout_seconds {
      dump_tail(tail, log, 120)
      terminate_if_live(pid)
      return Err(InstallerQemuTestError.Failed(kind: "qemu-timeout", message: f"timed out waiting for {ok}"))
    }

    time.sleep(1s)
    elapsed += 1
  }

  dump_tail(tail, log, 120)
  return Err(InstallerQemuTestError.Failed(kind: "qemu-exit", message: f"qemu exited before {ok}"))
}

pure ssh_args(ssh_key: Path, port: Int, known_hosts: Path, remote_command: Str) -> List[Str] {
  [
    "-i",
    ssh_key.display(),
    "-p",
    f"{port}",
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=2",
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    f"UserKnownHostsFile={known_hosts}",
    "-o",
    "GlobalKnownHostsFile=/dev/null",
    "-o",
    "LogLevel=ERROR",
    "-o",
    "KexAlgorithms=curve25519-sha256",
    "-o",
    "HostKeyAlgorithms=ssh-ed25519",
    "-o",
    "PubkeyAcceptedAlgorithms=ssh-ed25519",
    "pazu@127.0.0.1",
    remote_command,
  ]
}

proc ssh_guest(
  ssh: Path,
  ssh_key: Path,
  port: Int,
  known_hosts: Path,
  remote_command: Str,
) -> Result[Str] {
  let argv = ssh_args(ssh_key, port, known_hosts, remote_command)
  return run.text $ssh @argv ?
}

proc wait_for_ssh(
  pid: Int,
  kill: Path,
  tail: Path,
  ssh: Path,
  ssh_key: Path,
  port: Int,
  known_hosts: Path,
  target_log: Path,
  timeout_seconds: Int,
  cwd: Path,
) {
  var elapsed = 0

  while process_live(kill, pid, cwd) {
    if let Ok(output) = ssh_guest(ssh, ssh_key, port, known_hosts, "print \"LAPUTA_SSH_OK\"") {
      return when output.trim() == "LAPUTA_SSH_OK"
    }

    if elapsed >= timeout_seconds {
      dump_tail(tail, target_log, 160)
      return Err(InstallerQemuTestError.Failed(kind: "ssh-timeout", message: "timed out waiting for target ssh"))
    }

    time.sleep(1s)
    elapsed += 1
  }

  dump_tail(tail, target_log, 160)
  return Err(InstallerQemuTestError.Failed(kind: "qemu-exit", message: "qemu exited before target ssh was ready"))
}

proc assert_ssh_smoke(
  pid: Int,
  kill: Path,
  tail: Path,
  ssh: Path,
  ssh_key: Path,
  port: Int,
  known_hosts: Path,
  target_log: Path,
  timeout_seconds: Int,
  cwd: Path,
) {
  wait_for_ssh(pid, kill, tail, ssh, ssh_key, port, known_hosts, target_log, timeout_seconds, cwd)

  # xinit status uses signal-0 liveness which gets EPERM across UIDs
  # (SSH user is pazu, dropbear runs as root). Use sudo.
  let status = ssh_guest(ssh, ssh_key, port, known_hosts, "run /usr/bin/sudo /usr/bin/xinit status dropbear ?")?

  if ! ("dropbear running" in status) {
    print $status
    return Err(InstallerQemuTestError.Failed(kind: "ssh-dropbear", message: "dropbear status assertion failed"))
  }

  let result = ssh_guest(ssh, ssh_key, port, known_hosts, "run /bin/xshi --help ?")?

  if ! ("xshi 0.0.1" in result) {
    print $result
    return Err(InstallerQemuTestError.Failed(kind: "ssh-xshi", message: "xshi help assertion failed"))
  }
}

pure qemu_machine(arch: Str) -> Str {
  return "pc" when arch == "x86_64"

  "virt"
}

pure qemu_cpu(arch: Str) -> Str {
  return "max" when arch == "x86_64"

  "neoverse-n2"
}

pure qemu_block_device(arch: Str, drive: Str) -> Str {
  return f"virtio-blk-pci,drive={drive}" when arch == "x86_64"

  f"virtio-blk-device,drive={drive}"
}

pure qemu_net_device(arch: Str) -> Str {
  return "virtio-net-pci,netdev=net0" when arch == "x86_64"

  "virtio-net-device,netdev=net0"
}

pure qemu_rng_device(arch: Str) -> Str {
  return "virtio-rng-pci,rng=rng0" when arch == "x86_64"

  "virtio-rng-device,rng=rng0"
}

pure qemu_memory(arch: Str) -> Str {
  return "512M" when arch == "x86_64"

  "256M"
}

pure qemu_accel_args(arch: Str) -> List[Str] {
  return ["-accel", "kvm"] when arch == "x86_64"

  []
}

pure qemu_console_args(log: Path) -> List[Str] {
  ["-display", "none", "-serial", f"file:{log}", "-monitor", "none"]
}

pure installer_cmdline_default(arch: Str) -> Str {
  let console = if arch == "x86_64" { "console=ttyS0 console=tty0" } else { "console=ttyAMA0 console=tty0" }
  let video = if arch == "x86_64" { "vga=normal " } else { "" }
  let loglevel = if arch == "x86_64" { "7" } else { "4" }
  f"root=PARTUUID=55555555-5555-5555-5555-555555555555 rootfstype=ext4 rootwait rootdelay=2 rw {console} {video}loglevel={loglevel} devtmpfs.mount=1 init=/init XSH_LINUX_REAL=1 XSH_UNIX_REAL=1"
}

pure target_cmdline_default(arch: Str) -> Str {
  let console = if arch == "x86_64" { "console=ttyS0 console=tty0" } else { "console=ttyAMA0 console=tty0" }
  let video = if arch == "x86_64" { "vga=normal " } else { "" }
  let loglevel = if arch == "x86_64" { "7" } else { "4" }
  f"root=PARTUUID=33333333-3333-3333-3333-333333333333 rootfstype=ext4 rootwait rootdelay=2 rw {console} {video}loglevel={loglevel} devtmpfs.mount=1 init=/init XSH_LINUX_REAL=1 XSH_UNIX_REAL=1"
}

pure qemu_installer_args(
  arch: Str,
  qemu_name: Str,
  installer_kernel: Path,
  installer_cmdline: Str,
  installer_iso: Path,
  target_image: Path,
  installer_log: Path,
) -> List[Str] {
  let base = [qemu_name, "-M", qemu_machine(arch)].extend(qemu_accel_args(arch))

  let with_devices = base.extend(
    [
      "-cpu",
      qemu_cpu(arch),
      "-m",
      qemu_memory(arch),
      "-object",
      "rng-random,filename=/dev/urandom,id=rng0",
      "-device",
      qemu_rng_device(arch),
      "-kernel",
      installer_kernel.display(),
      "-append",
      installer_cmdline,
      "-drive",
      f"if=none,id=installer,format=raw,file={installer_iso}",
      "-device",
      qemu_block_device(arch, "installer"),
      "-drive",
      f"if=none,id=target,format=raw,file={target_image}",
      "-device",
      qemu_block_device(arch, "target"),
      "-netdev",
      "user,id=net0",
      "-device",
      qemu_net_device(arch),
    ],
  )

  with_devices.extend(qemu_console_args(installer_log))
}

pure qemu_target_args(
  arch: Str,
  qemu_name: Str,
  installer_kernel: Path,
  target_cmdline: Str,
  target_image: Path,
  target_log: Path,
  port: Int,
) -> List[Str] {
  let base = [qemu_name, "-M", qemu_machine(arch)].extend(qemu_accel_args(arch))

  let with_devices = base.extend(
    [
      "-cpu",
      qemu_cpu(arch),
      "-m",
      qemu_memory(arch),
      "-object",
      "rng-random,filename=/dev/urandom,id=rng0",
      "-device",
      qemu_rng_device(arch),
      "-kernel",
      installer_kernel.display(),
      "-append",
      target_cmdline,
      "-drive",
      f"if=none,id=target,format=raw,file={target_image}",
      "-device",
      qemu_block_device(arch, "target"),
      "-netdev",
      f"user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22",
      "-device",
      qemu_net_device(arch),
    ],
  )

  with_devices.extend(qemu_console_args(target_log))
}

proc clean_build_state(work: Path) {
  for name in [
    "rootfs-target",
    "rootfs-installer",
    "rootfs-tools",
    "pm-work-target-base",
    "pm-work-target-runtime",
    "pm-work-target-tools",
    "pm-work-installer-base",
    "pm-work-installer-tools",
    "pm-work-tools",
  ] {
    fp"{work}/{name}".remove(missing_ok: true)
  }

  # pm-out dirs hold remote-cache; keep the cache to avoid re-downloading packages.
  for name in [
    "pm-out-target-base",
    "pm-out-target-runtime",
    "pm-out-target-tools",
    "pm-out-installer-base",
    "pm-out-installer-tools",
    "pm-out-tools",
  ] {
    let out = fp"{work}/{name}"

    if out.exists() {
      for entry in fs.children(out)? {
        if entry.name != "remote-cache" {
          entry.path.remove()
        }
      }
    }
  }
}

proc kernel_source_env(root: Path, arch: Str) -> Result[Str] {
  let configured = host.installer_env_value("LAPUTA_INSTALLER_KERNEL_SOURCE", "")

  return configured when configured != ""

  let local_name = if arch == "x86_64" { "local-linux-x86_64.bzImage" } else { "local-linux-aarch64.Image" }
  let local_kernel = fp"{root}/target/laputa-installer/{local_name}"

  return local_kernel.display() when local_kernel.exists()

  ""
}

proc build_installer(
  root: Path,
  arch: Str,
  work: Path,
  installer_iso: Path,
  installer_kernel: Path,
  ssh_pubkey: Path,
  xsh: Path,
) {
  let kernel_package = host.installer_env_value("LAPUTA_INSTALLER_KERNEL_PACKAGE", "linux")

  var build_env: Record = {
    XSH_HOST: xsh.display(),
    LAPUTA_ROOT: root.display(),
    LAPUTA_INSTALLER_QEMU_SMOKE: "1",
    LAPUTA_INSTALLER_QEMU_AUTHORIZED_KEY: ssh_pubkey.display(),
    LAPUTA_INSTALLER_WORK: work.display(),
    LAPUTA_INSTALLER_ISO: installer_iso.display(),
    LAPUTA_INSTALLER_KERNEL: installer_kernel.display(),
    LAPUTA_INSTALLER_KERNEL_PACKAGE: kernel_package,
  }

  let kernel_source = kernel_source_env(root, arch)?

  if kernel_source != "" {
    build_env = {
      XSH_HOST: xsh.display(),
      LAPUTA_ROOT: root.display(),
      LAPUTA_INSTALLER_QEMU_SMOKE: "1",
      LAPUTA_INSTALLER_QEMU_AUTHORIZED_KEY: ssh_pubkey.display(),
      LAPUTA_INSTALLER_WORK: work.display(),
      LAPUTA_INSTALLER_ISO: installer_iso.display(),
      LAPUTA_INSTALLER_KERNEL: installer_kernel.display(),
      LAPUTA_INSTALLER_KERNEL_PACKAGE: kernel_package,
      LAPUTA_INSTALLER_KERNEL_SOURCE: kernel_source,
    }
  }

  host.installer_run_argv(xsh, ["xsh", fp"{root}/build-installer-common.xsh".display(), "--", arch], root, build_env)
}

proc main(...argv: List[Str]) [fs, process, env, time, error] {
  if ! argv.is_empty() {
    return Err(InstallerQemuTestError.Failed(kind: "argv", message: "installer-qemu-test.xsh does not accept arguments"))
  }

  let root = host.installer_env_path("LAPUTA_ROOT", fs.cwd()?)?
  let arch = host.installer_env_value("LAPUTA_INSTALLER_ARCH", "aarch64") |> host.installer_arch(_)?
  let work = host.installer_env_path("LAPUTA_INSTALLER_WORK", fp"{root}/target/laputa-installer-{arch}-qemu")?
  let installer_iso = host.installer_env_path("LAPUTA_INSTALLER_ISO", fp"{work}/laputa-installer-{arch}.iso")?
  let installer_kernel = host.installer_env_path("LAPUTA_INSTALLER_KERNEL", fp"{work}/laputa-installer-{arch}.vmlinuz")?
  let target_image = host.installer_env_path("LAPUTA_INSTALLER_TARGET_IMAGE", fp"{work}/laputa-target-128m.img")?
  let installer_log = host.installer_env_path("LAPUTA_INSTALLER_QEMU_LOG", fp"{work}/qemu-installer.log")?
  let target_log = host.installer_env_path("LAPUTA_TARGET_QEMU_LOG", fp"{work}/qemu-target.log")?

  let installer_cmdline = host.installer_env_value("LAPUTA_KERNEL_CMDLINE", installer_cmdline_default(arch)) |> host.installer_env_value(
    "LAPUTA_INSTALLER_KERNEL_CMDLINE",
    _,
  )

  let target_cmdline = host.installer_env_value("LAPUTA_KERNEL_CMDLINE", target_cmdline_default(arch)) |> host.installer_env_value(
    "LAPUTA_TARGET_KERNEL_CMDLINE",
    _,
  )

  let qemu_name = if arch == "x86_64" {
    host.installer_env_value("QEMU_SYSTEM_X86_64", "qemu-system-x86_64")
  } else {
    host.installer_env_value("QEMU_SYSTEM_AARCH64", "qemu-system-aarch64")
  }

  let qemu = command_path(qemu_name)?
  let ssh = host.installer_env_value("SSH", "ssh") |> command_path(_)?
  let ssh_keygen = host.installer_env_value("SSH_KEYGEN", "ssh-keygen") |> command_path(_)?
  let kill = command_path("kill")?
  let tail = command_path("tail")?
  let xsh = host.installer_env_path("XSH_HOST", process.which("xsh")?)?
  let target_ssh_port = env_int("LAPUTA_TARGET_SSH_PORT", 10022)?
  let ssh_key = host.installer_env_path("LAPUTA_TARGET_SSH_KEY", fp"{work}/qemu-smoke-ed25519")?
  let ssh_known_hosts = fp"{work}/qemu-smoke-known-hosts"
  let timeout_seconds = env_int("LAPUTA_INSTALLER_QEMU_TIMEOUT", 180)?
  ensure_dir(work)
  clean_build_state(work)
  ssh_key.remove(missing_ok: true)
  fp"{ssh_key}.pub".remove(missing_ok: true)
  ssh_known_hosts.remove(missing_ok: true)

  host.installer_run_argv(
    ssh_keygen,
    [
      "ssh-keygen",
      "-q",
      "-t",
      "ed25519",
      "-N",
      "",
      "-C",
      "laputa-qemu-smoke",
      "-f",
      ssh_key.display(),
    ],
    root,
  )

  build_installer(root, arch, work, installer_iso, installer_kernel, fp"{ssh_key}.pub", xsh)
  ensure_file(installer_iso, "installer-iso")
  ensure_file(installer_kernel, "installer-kernel")
  target_image.remove(missing_ok: true)
  installer_log.remove(missing_ok: true)
  target_log.remove(missing_ok: true)
  target_image.write("")
  target_image.truncate(128 * 1024 * 1024)

  let installer = spawn process.command_argv(
    qemu,
    qemu_installer_args(
      arch,
      qemu_name,
      installer_kernel,
      installer_cmdline,
      installer_iso,
      target_image,
      installer_log,
    ),
    cwd: root,
    env: {},
    stderr: /dev/null,
  )?

  defer terminate_if_live(installer.pid)

  wait_for_marker(
    installer.pid,
    kill,
    tail,
    installer_log,
    "LAPUTA_INSTALLER_CI_OK",
    "LAPUTA_INSTALLER_CI_FAILED",
    false,
    timeout_seconds,
    root,
  )

  time.sleep(3s)

  let target = spawn process.command_argv(
    qemu,
    qemu_target_args(arch, qemu_name, installer_kernel, target_cmdline, target_image, target_log, target_ssh_port),
    cwd: root,
    env: {},
    stderr: /dev/null,
  )?

  defer terminate_if_live(target.pid)

  wait_for_marker(
    target.pid,
    kill,
    tail,
    target_log,
    "LAPUTA_TARGET_CI_OK",
    "LAPUTA_TARGET_CI_FAILED",
    true,
    timeout_seconds,
    root,
  )

  assert_ssh_smoke(
    target.pid,
    kill,
    tail,
    ssh,
    ssh_key,
    target_ssh_port,
    ssh_known_hosts,
    target_log,
    timeout_seconds,
    root,
  )

  terminate_if_live(target.pid)
  print "installer qemu logs:" $installer_log $target_log
}

main(@args)
