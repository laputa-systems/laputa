#!/bin/xsh
error InstallerVirtAmd64Error = Failed(message: Str)

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

proc run_argv(target: Path, argv: List[Str], cwd: Path, envs: Record = {}) [process, error] {
  let status = process.run(process.command_argv(target, argv, cwd, envs))?

  if status.ok {
    return
  }

  if status.exited() {
    abort(status.exit_code()?)
  }

  return Err(InstallerVirtAmd64Error.Failed(f"${argv[0]} was signaled"))
}

proc main(...argv: List[Str]) [fs, process, env, error] {
  if argv.len() > 0 {
    return Err(InstallerVirtAmd64Error.Failed("build-installer-virt-amd64.xsh does not accept subcommands"))
  }

  let root = env_path("LAPUTA_ROOT", fs.cwd()?)?
  let xsh = env_path("XSH_HOST", process.which("xsh")?)?

  run_argv(
    xsh,
    ["xsh", fp"${root}/build-installer-common.xsh".display(), "--", "amd64"],
    root,
    {XSH_HOST: xsh.display(), LAPUTA_ROOT: root.display(), LAPUTA_INSTALLER_KERNEL_PACKAGE: "linux-virt-amd64"},
  )?
}

main(@args)?
