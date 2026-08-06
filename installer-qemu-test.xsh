#!/bin/xsh
error InstallerQemuTestError = Failed(kind: Str, message: Str)

proc env_value(name: Str, fallback: Str) [env] -> Str {
  let value = (env.get(name) ?? "").trim()

  if value == "" {
    return fallback
  }

  return value
}

proc env_path(name: Str, fallback: Path) [env, error] -> Result[Path] {
  return fp"${env_value(name, fallback.display())}"
}

proc env_int(name: Str, fallback: Int) [env, error] -> Result[Int] {
  return env_value(name, f"${fallback}").parse_int()?
}

pure normalize_arch(arch: Str) -> Result[Str] {
  if arch == "amd64" {
    return "x86_64"
  }

  if arch == "arm64" {
    return "aarch64"
  }

  if arch == "aarch64" or arch == "x86_64" {
    return arch
  }

  return Err(InstallerQemuTestError.Failed("arch", f"unsupported installer arch ${arch}"))
}

proc command_path(name: Str) [process, error] -> Result[Path] {
  if "/" in name {
    return fp"${name}"
  }

  return process.which(name)?
}

proc ensure_dir(path_value: Path) [fs, error] {
  if fs.exists(path_value)? {
    return
  }

  path_value.mkdir()?
}

proc ensure_file(path_value: Path, kind: Str) [fs, error] {
  if fs.exists(path_value)? {
    return
  }

  return Err(InstallerQemuTestError.Failed(kind, f"missing ${path_value.display()}"))
}

proc remove_tree(path_value: Path) [fs, error] {
  if ! fs.exists(path_value)? {
    return
  }

  let meta = path_value.metadata()?

  if meta.kind != "dir" {
    path_value.remove()?
    return
  }

  for child in fs.ls(path_value)? {
    if child.kind == "dir" {
      remove_tree(child.path)?
    } else {
      child.path.remove()?
    }
  }

  path_value.remove_dir()?
}

proc run_argv(target: Path, argv: List[Str], cwd: Path, envs: Record = {}) [process, error] {
  let status = process.run(process.command_argv(target, argv, cwd, envs))?

  if status.ok {
    return
  }

  if status.exited() {
    abort(status.exit_code()?)
  }

  return Err(InstallerQemuTestError.Failed("command", f"${argv[0]} was signaled"))
}

proc process_live(kill: Path, pid: Int, cwd: Path) [process, error] -> Result[Bool] {
  let status = process.run(process.command_argv(kill, ["kill", "-0", f"${pid}"], cwd, {}))?
  return status.ok
}

proc terminate_if_live(pid: Int) [process] {
  if pid <= 0 {
    return
  }

  match process.kill(pid, signal: "TERM") {
    Ok(_) => {}
    Err(_) => {}
  }
}

proc dump_tail(tail: Path, log: Path, lines: Int) [fs, process, error] {
  if ! fs.exists(log)? {
    return
  }

  match run.text $tail "-n" $lines $log {
    Ok(out) => {
      if out != "" {
        print $out
      }
    }
    Err(_) => {}
  }
}

proc has_line_marker(log: Path, marker: Str) [fs, error] -> Result[Bool] {
  if ! fs.exists(log)? {
    return false
  }

  let body = fs.read_text(log)?.replace("\r", "")

  for line in body.lines() {
    if line.trim() == marker {
      return true
    }
  }

  return false
}

proc has_panic(log: Path) [fs, error] -> Result[Bool] {
  if ! fs.exists(log)? {
    return false
  }

  let body = fs.read_text(log)?
  return "Kernel panic" in body or "not syncing" in body or "Attempted to kill init" in body
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
) [fs, process, time, error] {
  var elapsed = 0

  while process_live(kill, pid, cwd)? {
    if has_line_marker(log, ok)? {
      time.sleep(2s)?

      if has_panic(log)? {
        dump_tail(tail, log, 120)?
        terminate_if_live(pid)
        return Err(InstallerQemuTestError.Failed("qemu", f"${ok} was followed by a kernel panic"))
      }

      if keep_running {
        return
      }

      terminate_if_live(pid)
      return
    }

    if has_line_marker(log, failed)? or has_panic(log)? {
      dump_tail(tail, log, 120)?
      terminate_if_live(pid)
      return Err(InstallerQemuTestError.Failed("qemu", f"failed while waiting for ${ok}"))
    }

    if elapsed >= timeout_seconds {
      dump_tail(tail, log, 120)?
      terminate_if_live(pid)
      return Err(InstallerQemuTestError.Failed("qemu-timeout", f"timed out waiting for ${ok}"))
    }

    time.sleep(1s)?
    elapsed += 1
  }

  dump_tail(tail, log, 120)?
  return Err(InstallerQemuTestError.Failed("qemu-exit", f"qemu exited before ${ok}"))
}

pure ssh_args(ssh_key: Path, port: Int, known_hosts: Path, remote_command: Str) -> List[Str] {
  return [
    "-i",
    ssh_key.display(),
    "-p",
    f"${port}",
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=2",
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    f"UserKnownHostsFile=${known_hosts.display()}",
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
) [process, error] -> Result[Str] {
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
) [fs, process, time, error] {
  var elapsed = 0

  while process_live(kill, pid, cwd)? {
    match ssh_guest(ssh, ssh_key, port, known_hosts, "print \"LAPUTA_SSH_OK\"") {
      Ok(output) => {
        if output.trim() == "LAPUTA_SSH_OK" {
          return
        }
      }
      Err(_) => {}
    }

    if elapsed >= timeout_seconds {
      dump_tail(tail, target_log, 160)?
      return Err(InstallerQemuTestError.Failed("ssh-timeout", "timed out waiting for target ssh"))
    }

    time.sleep(1s)?
    elapsed += 1
  }

  dump_tail(tail, target_log, 160)?
  return Err(InstallerQemuTestError.Failed("qemu-exit", "qemu exited before target ssh was ready"))
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
) [fs, process, time, error] {
  wait_for_ssh(pid, kill, tail, ssh, ssh_key, port, known_hosts, target_log, timeout_seconds, cwd)?

  # xinit status uses signal-0 liveness which gets EPERM across UIDs
  # (SSH user is pazu, dropbear runs as root). Use sudo.
  let status = ssh_guest(ssh, ssh_key, port, known_hosts, "run /usr/bin/sudo /usr/bin/xinit status dropbear ?")?

  if ! ("dropbear running" in status) {
    print $status
    return Err(InstallerQemuTestError.Failed("ssh-dropbear", "dropbear status assertion failed"))
  }

  let result = ssh_guest(ssh, ssh_key, port, known_hosts, "run /bin/xshi --help ?")?

  if ! ("xshi 0.0.1" in result) {
    print $result
    return Err(InstallerQemuTestError.Failed("ssh-xshi", "xshi help assertion failed"))
  }
}

pure qemu_machine(arch: Str) -> Str {
  if arch == "x86_64" {
    return "pc"
  }

  return "virt"
}

pure qemu_cpu(arch: Str) -> Str {
  if arch == "x86_64" {
    return "max"
  }

  return "neoverse-n2"
}

pure qemu_block_device(arch: Str, drive: Str) -> Str {
  if arch == "x86_64" {
    return f"virtio-blk-pci,drive=${drive}"
  }

  return f"virtio-blk-device,drive=${drive}"
}

pure qemu_net_device(arch: Str) -> Str {
  if arch == "x86_64" {
    return "virtio-net-pci,netdev=net0"
  }

  return "virtio-net-device,netdev=net0"
}

pure qemu_rng_device(arch: Str) -> Str {
  if arch == "x86_64" {
    return "virtio-rng-pci,rng=rng0"
  }

  return "virtio-rng-device,rng=rng0"
}

pure qemu_memory(arch: Str) -> Str {
  if arch == "x86_64" {
    return "512M"
  }

  return "256M"
}

pure qemu_accel_args(arch: Str) -> List[Str] {
  if arch == "x86_64" {
    return ["-accel", "kvm"]
  }

  []
}

pure qemu_console_args(log: Path) -> List[Str] {
  return ["-display", "none", "-serial", f"file:${log.display()}", "-monitor", "none"]
}

pure installer_cmdline_default(arch: Str) -> Str {
  let console = if arch == "x86_64" { "console=ttyS0 console=tty0" } else { "console=ttyAMA0 console=tty0" }
  let video = if arch == "x86_64" { "vga=normal " } else { "" }
  let loglevel = if arch == "x86_64" { "7" } else { "4" }
  return f"root=PARTUUID=55555555-5555-5555-5555-555555555555 rootfstype=ext4 rootwait rootdelay=2 rw ${console} ${video}loglevel=${loglevel} devtmpfs.mount=1 init=/init XSH_LINUX_REAL=1 XSH_UNIX_REAL=1"
}

pure target_cmdline_default(arch: Str) -> Str {
  let console = if arch == "x86_64" { "console=ttyS0 console=tty0" } else { "console=ttyAMA0 console=tty0" }
  let video = if arch == "x86_64" { "vga=normal " } else { "" }
  let loglevel = if arch == "x86_64" { "7" } else { "4" }
  return f"root=PARTUUID=33333333-3333-3333-3333-333333333333 rootfstype=ext4 rootwait rootdelay=2 rw ${console} ${video}loglevel=${loglevel} devtmpfs.mount=1 init=/init XSH_LINUX_REAL=1 XSH_UNIX_REAL=1"
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
      f"if=none,id=installer,format=raw,file=${installer_iso.display()}",
      "-device",
      qemu_block_device(arch, "installer"),
      "-drive",
      f"if=none,id=target,format=raw,file=${target_image.display()}",
      "-device",
      qemu_block_device(arch, "target"),
      "-netdev",
      "user,id=net0",
      "-device",
      qemu_net_device(arch),
    ],
  )

  return with_devices.extend(qemu_console_args(installer_log))
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
      f"if=none,id=target,format=raw,file=${target_image.display()}",
      "-device",
      qemu_block_device(arch, "target"),
      "-netdev",
      f"user,id=net0,hostfwd=tcp:127.0.0.1:${port}-:22",
      "-device",
      qemu_net_device(arch),
    ],
  )

  return with_devices.extend(qemu_console_args(target_log))
}

proc clean_build_state(work: Path) [fs, error] {
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
    remove_tree(fp"${work}/${name}")?
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
    let out = fp"${work}/${name}"

    if fs.exists(out)? {
      for entry in fs.children(out)? {
        if entry.name != "remote-cache" {
          remove_tree(entry.path)?
        }
      }
    }
  }
}

proc kernel_source_env(root: Path, arch: Str) [fs, env, error] -> Result[Str] {
  let configured = (env.get("LAPUTA_INSTALLER_KERNEL_SOURCE") ?? "").trim()

  if configured != "" {
    return configured
  }

  let local_name = if arch == "x86_64" { "local-linux-x86_64.bzImage" } else { "local-linux-aarch64.Image" }
  let local_kernel = fp"${root}/target/laputa-installer/${local_name}"

  if fs.exists(local_kernel)? {
    return local_kernel.display()
  }

  return ""
}

proc build_installer(
  root: Path,
  arch: Str,
  work: Path,
  installer_iso: Path,
  installer_kernel: Path,
  ssh_pubkey: Path,
  xsh: Path,
) [fs, process, env, error] {
  let kernel_package = env_value(
    "LAPUTA_INSTALLER_KERNEL_PACKAGE",
    if arch == "x86_64" {
      "linux-virt-amd64"
    } else {
      "linux"
    },
  )

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

  run_argv(xsh, ["xsh", fp"${root}/build-installer-common.xsh".display(), "--", arch], root, build_env)?
}

proc main(...argv: List[Str]) [fs, process, env, time, error] {
  if argv.len() > 0 {
    return Err(InstallerQemuTestError.Failed("argv", "installer-qemu-test.xsh does not accept arguments"))
  }

  let root = env_path("LAPUTA_ROOT", fs.cwd()?)?
  let arch = normalize_arch(env_value("LAPUTA_INSTALLER_ARCH", "aarch64"))?
  let work = env_path("LAPUTA_INSTALLER_WORK", fp"${root}/target/laputa-installer-${arch}-qemu")?
  let installer_iso = env_path("LAPUTA_INSTALLER_ISO", fp"${work}/laputa-installer-${arch}.iso")?
  let installer_kernel = env_path("LAPUTA_INSTALLER_KERNEL", fp"${work}/laputa-installer-${arch}.vmlinuz")?
  let target_image = env_path("LAPUTA_INSTALLER_TARGET_IMAGE", fp"${work}/laputa-target-128m.img")?
  let installer_log = env_path("LAPUTA_INSTALLER_QEMU_LOG", fp"${work}/qemu-installer.log")?
  let target_log = env_path("LAPUTA_TARGET_QEMU_LOG", fp"${work}/qemu-target.log")?

  let installer_cmdline = env_value(
    "LAPUTA_INSTALLER_KERNEL_CMDLINE",
    env_value("LAPUTA_KERNEL_CMDLINE", installer_cmdline_default(arch)),
  )

  let target_cmdline = env_value(
    "LAPUTA_TARGET_KERNEL_CMDLINE",
    env_value("LAPUTA_KERNEL_CMDLINE", target_cmdline_default(arch)),
  )

  let qemu_name = if arch == "x86_64" {
    env_value("QEMU_SYSTEM_X86_64", "qemu-system-x86_64")
  } else {
    env_value("QEMU_SYSTEM_AARCH64", "qemu-system-aarch64")
  }

  let qemu = command_path(qemu_name)?
  let ssh = command_path(env_value("SSH", "ssh"))?
  let ssh_keygen = command_path(env_value("SSH_KEYGEN", "ssh-keygen"))?
  let kill = command_path("kill")?
  let tail = command_path("tail")?
  let xsh = env_path("XSH_HOST", process.which("xsh")?)?
  let target_ssh_port = env_int("LAPUTA_TARGET_SSH_PORT", 10022)?
  let ssh_key = env_path("LAPUTA_TARGET_SSH_KEY", fp"${work}/qemu-smoke-ed25519")?
  let ssh_known_hosts = fp"${work}/qemu-smoke-known-hosts"
  let timeout_seconds = env_int("LAPUTA_INSTALLER_QEMU_TIMEOUT", 180)?
  ensure_dir(work)?
  clean_build_state(work)?
  fs.remove(ssh_key, missing_ok: true)?
  fs.remove(fp"${ssh_key}.pub", missing_ok: true)?
  fs.remove(ssh_known_hosts, missing_ok: true)?

  run_argv(
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
  )?

  build_installer(root, arch, work, installer_iso, installer_kernel, fp"${ssh_key}.pub", xsh)?
  ensure_file(installer_iso, "installer-iso")?
  ensure_file(installer_kernel, "installer-kernel")?
  fs.remove(target_image, missing_ok: true)?
  fs.remove(installer_log, missing_ok: true)?
  fs.remove(target_log, missing_ok: true)?
  fs.write(target_image, "")?
  target_image.truncate(128 * 1024 * 1024)?

  # TODO: use stderr: /dev/null once spawn supports it (see ../xsh/LANG.md)
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
  )?

  time.sleep(3s)?

  # TODO: use stderr: /dev/null once spawn supports it (see ../xsh/LANG.md)
  let target = spawn process.command_argv(
    qemu,
    qemu_target_args(arch, qemu_name, installer_kernel, target_cmdline, target_image, target_log, target_ssh_port),
    cwd: root,
    env: {},
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
  )?

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
  )?

  terminate_if_live(target.pid)
  print "installer qemu logs:" $installer_log $target_log
}

main(@args)?
