##! Host-side helpers shared by the installer build, size report, and QEMU scripts.
# These run on the build host only. The guest installer (`setup-laputa.xsh`) is
# installed alone into the image and resolves no checkout modules, so it keeps
# its own helpers.

## Installer host failures that are not a child's exit status.
export error InstallerHostError = Failed(message: Str)

## Read an environment setting, treating an unset or blank value as absent so
## an empty `VAR=` from a Makefile or wrapper falls back to the default.
export proc installer_env_value(name: Str, fallback: Str) [env] -> Str {
  let value = (env.get(name) ?? "").trim()

  return fallback when value == ""

  value
}

## Read a path-valued environment setting with `installer_env_value` rules.
export proc installer_env_path(name: Str, fallback: Path) [env, error] -> Result[Path] {
  fp"{installer_env_value(name, fallback.display())}"
}

## Normalize a Docker or kernel architecture spelling to the installer's arch name.
export pure installer_arch(arch: Str) -> Result[Str] {
  return "aarch64" when arch == "arm64" or arch == "aarch64"

  return "x86_64" when arch == "amd64" or arch == "x86_64"

  Err(InstallerHostError.Failed(f"unsupported installer arch {arch}"))
}

## Run one step of the installer pipeline. A failing child aborts this script
## with the child's own exit code, so make and nested scripts report the
## original status instead of a wrapped error; only a signaled child is an error.
export proc installer_run_argv(target: Path, argv: List[Str], cwd: Path, envs: Record = {}) [process, error] {
  let status = process.run(process.command_argv(target, argv, cwd, envs))?

  return when status.ok

  if status.exited() {
    abort(status.exit_code()?)
  }

  return Err(InstallerHostError.Failed(f"{argv[0]} was signaled"))
}
