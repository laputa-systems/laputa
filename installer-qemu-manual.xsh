#!/bin/xsh
use installer.host

proc parse_size(value: Str) -> Result[Int] {
  let trimmed = value.trim()

  if trimmed.ends_with("G") {
    return trimmed.split("G")[0].parse_int()? * 1024 * 1024 * 1024
  }

  return trimmed.split("M")[0].parse_int()? * 1024 * 1024 when trimmed.ends_with("M")

  return trimmed.split("K")[0].parse_int()? * 1024 when trimmed.ends_with("K")

  trimmed.parse_int()?
}

proc command_path(name: Str) -> Result[Path] {
  return fp"{name}" when "/" in name

  process.which(name)?
}

proc main() [fs, process, env, error] {
  let root = host.installer_env_path("LAPUTA_ROOT", fs.cwd()?)?
  let work = host.installer_env_path("LAPUTA_INSTALLER_WORK", fp"{root}/target/laputa-installer")?
  let installer_iso = host.installer_env_path("LAPUTA_INSTALLER_ISO", fp"{work}/laputa-installer-manual-aarch64.iso")?
  let installer_kernel = host.installer_env_path("LAPUTA_INSTALLER_KERNEL", fp"{work}/laputa-installer-aarch64.vmlinuz")?
  let target_image = host.installer_env_path("LAPUTA_INSTALLER_TARGET_IMAGE", fp"{work}/laputa-target-manual.img")?
  let target_size = host.installer_env_value("LAPUTA_INSTALLER_TARGET_SIZE", "1G") |> parse_size(_)?

  let kernel_cmdline = host.installer_env_value(
    "LAPUTA_KERNEL_CMDLINE",
    "root=PARTUUID=55555555-5555-5555-5555-555555555555 rootfstype=ext4 rootwait rootdelay=2 rw console=ttyAMA0 console=tty0 loglevel=4 devtmpfs.mount=1 init=/init XSH_LINUX_REAL=1 XSH_UNIX_REAL=1",
  ) |> host.installer_env_value(
    "LAPUTA_INSTALLER_KERNEL_CMDLINE",
    _,
  )

  let qemu_name = host.installer_env_value("QEMU_SYSTEM_AARCH64", "qemu-system-aarch64")
  let qemu = command_path(qemu_name)?
  let xsh = host.installer_env_path("XSH_HOST", process.which("xsh")?)?
  let kernel_source_raw = host.installer_env_value("LAPUTA_INSTALLER_KERNEL_SOURCE", "")
  let local_kernel = fp"{root}/target/laputa-installer/local-linux-aarch64.Image"

  let kernel_source = if kernel_source_raw != "" {
    kernel_source_raw
  } else if local_kernel.exists()? {
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

  host.installer_run_argv(xsh, ["xsh", fp"{root}/build-installer-image.xsh".display()], root, build_env)
  let installer_iso_meta = installer_iso.metadata()?
  let installer_kernel_meta = installer_kernel.metadata()?
  let _ = {installer_iso_meta, installer_kernel_meta}
  target_image.remove(missing_ok: true)
  target_image.write("")
  target_image.truncate(target_size)
  print "manual target disk:" $target_image
  print "inside the installer, run: setup-laputa"
  print "CI-sized disk run: setup-laputa --ci"

  host.installer_run_argv(
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
      f"if=none,id=installer,format=raw,file={installer_iso}",
      "-device",
      "virtio-blk-device,drive=installer",
      "-drive",
      f"if=none,id=target,format=raw,file={target_image}",
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
  )
}
