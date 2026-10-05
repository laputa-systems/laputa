#!/bin/xsh
use installer.host

error InstallerReportError = Failed(message: Str)

proc arch_envs(arch: Str, root: Path, work: Path, iso: Path, kernel: Path, xsh: Path) [env] -> Record {
  {
    LAPUTA_INSTALLER_ARCH: arch,
    LAPUTA_INSTALLER_WORK: work.display(),
    LAPUTA_INSTALLER_ISO: iso.display(),
    LAPUTA_INSTALLER_KERNEL: kernel.display(),
    LAPUTA_TARGET_ESP_MB: host.installer_env_value("LAPUTA_TARGET_ESP_MB", "16"),
    LAPUTA_INSTALLER_ROOT_MB: host.installer_env_value("LAPUTA_INSTALLER_ROOT_MB", ""),
    LAPUTA_INSTALLER_KERNEL_PACKAGE: host.installer_env_value("LAPUTA_INSTALLER_KERNEL_PACKAGE", "linux"),
    LAPUTA_REPO_URL: host.installer_env_value("LAPUTA_REPO_URL", "http://127.0.0.1:3000"),
    LAPUTA_ROOT: root.display(),
    XSH_HOST: xsh.display(),
    XSH_MODULE_PATH: root.display(),
  }
}

proc build_installer(raw_arch: Str) [fs, process, env, error] {
  let arch = host.installer_arch(raw_arch)?
  let root = host.installer_env_path("LAPUTA_ROOT", fs.cwd()?)?
  let work = host.installer_env_path("LAPUTA_INSTALLER_WORK", fp"{root}/target/laputa-installer-{arch}")?
  let iso = host.installer_env_path("LAPUTA_INSTALLER_ISO", fp"{work}/laputa-installer-{arch}.iso")?
  let kernel = host.installer_env_path("LAPUTA_INSTALLER_KERNEL", fp"{work}/laputa-installer-{arch}.vmlinuz")?
  let xsh = host.installer_env_path("XSH_HOST", process.which("xsh")?)?
  let envs = arch_envs(arch, root, work, iso, kernel, xsh)
  host.installer_run_argv(xsh, ["xsh", fp"{root}/build-installer-image.xsh".display()], root, envs)

  host.installer_run_argv(
    xsh,
    ["xsh", fp"{root}/installer-size.xsh".display(), "--", arch, work.display(), iso.display(), kernel.display()],
    root,
    {LAPUTA_ROOT: root.display()},
  )
}

proc main(...argv: List[Str]) [fs, process, env, error] {
  guard argv.len() == 1 else {
    return Err(InstallerReportError.Failed("usage: build-installer-common.xsh ARCH"))
  }

  build_installer(argv[0])
}

main(@args)
