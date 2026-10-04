#!/bin/xsh
error InstallerReportError = Failed(message: Str)

proc env_value(name: Str, fallback: Str) [env] -> Str {
  let value = env.get(name) ?? ""

  return fallback when value == ""

  value
}

proc env_path(name: Str, fallback: Path) [env, error] -> Result[Path] {
  fp"{env_value(name, fallback.display())}"
}

proc run_argv(target: Path, argv: List[Str], cwd: Path, envs: Record = {}) [process, error] {
  let status = process.run(process.command_argv(target, argv, cwd, envs))?

  return when status.ok

  if status.exited() {
    abort(status.exit_code()?)
  }

  return Err(InstallerReportError.Failed(f"{argv[0]} was signaled"))
}

proc arch_envs(arch: Str, root: Path, work: Path, iso: Path, kernel: Path, xsh: Path) [env] -> Record {
  {
    LAPUTA_INSTALLER_ARCH: arch,
    LAPUTA_INSTALLER_WORK: work.display(),
    LAPUTA_INSTALLER_ISO: iso.display(),
    LAPUTA_INSTALLER_KERNEL: kernel.display(),
    LAPUTA_TARGET_ESP_MB: env_value("LAPUTA_TARGET_ESP_MB", "16"),
    LAPUTA_INSTALLER_ROOT_MB: env_value("LAPUTA_INSTALLER_ROOT_MB", ""),
    LAPUTA_INSTALLER_KERNEL_PACKAGE: env_value("LAPUTA_INSTALLER_KERNEL_PACKAGE", "linux"),
    LAPUTA_REPO_URL: env_value("LAPUTA_REPO_URL", "http://127.0.0.1:3000"),
    LAPUTA_ROOT: root.display(),
    XSH_HOST: xsh.display(),
    XSH_MODULE_PATH: root.display(),
  }
}

pure normalize_arch(arch: Str) -> Result[Str] {
  return "aarch64" when arch == "arm64" or arch == "aarch64"

  return "x86_64" when arch == "amd64" or arch == "x86_64"

  Err(InstallerReportError.Failed(f"unsupported installer arch {arch}"))
}

proc build_installer(raw_arch: Str) [fs, process, env, error] {
  let arch = normalize_arch(raw_arch)?
  let root = env_path("LAPUTA_ROOT", fs.cwd()?)?
  let work = env_path("LAPUTA_INSTALLER_WORK", fp"{root}/target/laputa-installer-{arch}")?
  let iso = env_path("LAPUTA_INSTALLER_ISO", fp"{work}/laputa-installer-{arch}.iso")?
  let kernel = env_path("LAPUTA_INSTALLER_KERNEL", fp"{work}/laputa-installer-{arch}.vmlinuz")?
  let xsh = env_path("XSH_HOST", process.which("xsh")?)?
  let envs = arch_envs(arch, root, work, iso, kernel, xsh)
  run_argv(xsh, ["xsh", fp"{root}/build-installer-image.xsh".display()], root, envs)?

  run_argv(
    xsh,
    ["xsh", fp"{root}/installer-size.xsh".display(), "--", arch, work.display(), iso.display(), kernel.display()],
    root,
    {LAPUTA_ROOT: root.display()},
  )?
}

proc main(...argv: List[Str]) [fs, process, env, error] {
  guard argv.len() == 1 else {
    return Err(InstallerReportError.Failed("usage: build-installer-common.xsh ARCH"))
  }

  build_installer(argv[0])?
}

main(@args)?
