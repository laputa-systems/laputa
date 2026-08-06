#!/bin/xsh
error InstallerQemuError = Failed(message: Str)

proc env_value(name: Str, fallback: Str) [env] -> Str {
  let value = env.get(name) ?? ""

  if value == "" {
    return fallback
  }

  return value
}

proc env_path(name: Str, fallback: Path) [env, error] -> Result[Path] {
  return fp"${env_value(name, fallback.display())}"
}

proc parse_size(value: Str) [error] -> Result[Int] {
  let trimmed = value.trim()

  if trimmed.ends_with("G") {
    return trimmed.split("G")[0].parse_int()? * 1024 * 1024 * 1024
  }

  if trimmed.ends_with("M") {
    return trimmed.split("M")[0].parse_int()? * 1024 * 1024
  }

  if trimmed.ends_with("K") {
    return trimmed.split("K")[0].parse_int()? * 1024
  }

  return trimmed.parse_int()?
}

proc command_path(name: Str) [process, error] -> Result[Path] {
  if "/" in name {
    return fp"${name}"
  }

  return process.which(name)?
}

proc run_argv(target: Path, argv: List[Str], cwd: Path, envs: Record = {}) [process, error] {
  let status = process.run(process.command_argv(target, argv, cwd, envs))?

  if status.ok {
    return
  }

  if status.exited() {
    abort(status.exit_code()?)
  }

  return Err(InstallerQemuError.Failed(f"${argv[0]} was signaled"))
}

proc main() [fs, process, env, error] {
  let root = env_path("LAPUTA_ROOT", fs.cwd()?)?
  let work = env_path("LAPUTA_INSTALLER_WORK", fp"${root}/target/laputa-installer")?
  let installer_iso = env_path("LAPUTA_INSTALLER_ISO", fp"${work}/laputa-installer-manual-aarch64.iso")?
  let installer_kernel = env_path("LAPUTA_INSTALLER_KERNEL", fp"${work}/laputa-installer-aarch64.vmlinuz")?
  let target_image = env_path("LAPUTA_INSTALLER_TARGET_IMAGE", fp"${work}/laputa-target-manual.img")?
  let target_size = parse_size(env_value("LAPUTA_INSTALLER_TARGET_SIZE", "1G"))?

  let kernel_cmdline = env_value(
    "LAPUTA_INSTALLER_KERNEL_CMDLINE",
    env_value(
      "LAPUTA_KERNEL_CMDLINE",
      "root=PARTUUID=55555555-5555-5555-5555-555555555555 rootfstype=ext4 rootwait rootdelay=2 rw console=ttyAMA0 console=tty0 loglevel=4 devtmpfs.mount=1 init=/init XSH_LINUX_REAL=1 XSH_UNIX_REAL=1",
    ),
  )

  let qemu_name = env_value("QEMU_SYSTEM_AARCH64", "qemu-system-aarch64")
  let qemu = command_path(qemu_name)?
  let xsh = env_path("XSH_HOST", process.which("xsh")?)?
  let kernel_source_raw = env_value("LAPUTA_INSTALLER_KERNEL_SOURCE", "")
  let local_kernel = fp"${root}/target/laputa-installer/local-linux-aarch64.Image"

  let kernel_source = if kernel_source_raw != "" {
    kernel_source_raw
  } else if fs.exists(local_kernel)? {
    local_kernel.display()
  } else {
    ""
  }

  var build_env: Record = {
    XSH_HOST: xsh.display(),
    LAPUTA_ROOT: root.display(),
    LAPUTA_INSTALLER_CI: "0",
    LAPUTA_INSTALLER_WORK: work.display(),
    LAPUTA_INSTALLER_ISO: installer_iso.display(),
    LAPUTA_INSTALLER_KERNEL: installer_kernel.display(),
  }

  if kernel_source != "" {
    build_env = {
      XSH_HOST: xsh.display(),
      LAPUTA_ROOT: root.display(),
      LAPUTA_INSTALLER_CI: "0",
      LAPUTA_INSTALLER_WORK: work.display(),
      LAPUTA_INSTALLER_ISO: installer_iso.display(),
      LAPUTA_INSTALLER_KERNEL: installer_kernel.display(),
      LAPUTA_INSTALLER_KERNEL_SOURCE: kernel_source,
    }
  }

  run_argv(xsh, ["xsh", fp"${root}/build-installer-image.xsh".display()], root, build_env)?
  let installer_iso_meta = installer_iso.metadata()?
  let installer_kernel_meta = installer_kernel.metadata()?
  let _ = {installer_iso_meta, installer_kernel_meta}
  fs.remove(target_image, missing_ok: true)?
  fs.write(target_image, "")?
  target_image.truncate(target_size)?
  print "manual target disk:" $target_image
  print "inside the installer, run: setup-laputa"
  print "CI-sized disk run: setup-laputa --ci"

  run_argv(
    qemu,
    [
      qemu_name,
      "-M",
      "virt",
      "-cpu",
      "neoverse-n2",
      "-m",
      "256M",
      "-nographic",
      "-kernel",
      installer_kernel.display(),
      "-append",
      kernel_cmdline,
      "-drive",
      f"if=none,id=installer,format=raw,file=${installer_iso.display()}",
      "-device",
      "virtio-blk-device,drive=installer",
      "-drive",
      f"if=none,id=target,format=raw,file=${target_image.display()}",
      "-device",
      "virtio-blk-device,drive=target",
      "-netdev",
      "user,id=net0",
      "-device",
      "virtio-net-device,netdev=net0",
      "-serial",
      "stdio",
      "-monitor",
      "none",
    ],
    root,
  )?
}
