##! Host-side helpers shared by the installer build, size report, and QEMU scripts.

## Read an environment setting, treating an unset or blank value as absent so
## an empty `VAR=` from a Makefile or wrapper falls back to the default.
export proc installer_env_value(name: Str, fallback: Str) [env] -> Str {
  let value = (env.get(name) ?? "").trim()

  return fallback when value == ""

  value
}

## Read a path-valued environment setting with `installer_env_value` rules.
export proc installer_env_path(name: Str, fallback: Path) [env, error] -> Result[Path, Error] {
  fp"{installer_env_value(name, fallback.display())}"
}

## Normalize a Docker or kernel architecture spelling to the installer's arch name.
export pure installer_arch(arch: Str) -> Result[Str, Error] {
  return "aarch64" when arch == "arm64" or arch == "aarch64"

  return "x86_64" when arch == "amd64" or arch == "x86_64"

  fail f"unsupported installer arch {arch}"
}

## Selects the caller-specific values in the installer image build environment.
export enum InstallerBuildPurpose { Manual, QemuSmoke(Path, Str) }

## Select the manual installer image build environment.
export pure installer_manual_build_purpose() -> InstallerBuildPurpose {
  Manual
}

## Select the QEMU smoke image build environment.
export pure installer_qemu_smoke_build_purpose(authorized_key: Path, kernel_package: Str) -> InstallerBuildPurpose {
  QemuSmoke(authorized_key, kernel_package)
}

## Build the environment passed to either installer image builder.
export pure installer_build_environment(
  purpose: InstallerBuildPurpose,
  xsh: Path,
  root: Path,
  work: Path,
  installer_iso: Path,
  installer_kernel: Path,
  kernel_source: Str?,
) -> Record {
  let shared = {
    XSH_HOST: xsh.display(),
    LAPUTA_ROOT: root.display(),
    LAPUTA_INSTALLER_WORK: work.display(),
    LAPUTA_INSTALLER_ISO: installer_iso.display(),
    LAPUTA_INSTALLER_KERNEL: installer_kernel.display(),
  }

  match purpose {
    Manual => {
      if kernel_source == null {
        {...shared, LAPUTA_INSTALLER_CI: "0"}
      } else {
        {...shared, LAPUTA_INSTALLER_CI: "0", LAPUTA_INSTALLER_KERNEL_SOURCE: kernel_source}
      }
    }
    QemuSmoke(authorized_key, kernel_package) => {
      if kernel_source == null {
        {
          ...shared,
          LAPUTA_INSTALLER_QEMU_SMOKE: "1",
          LAPUTA_INSTALLER_QEMU_AUTHORIZED_KEY: authorized_key.display(),
          LAPUTA_INSTALLER_KERNEL_PACKAGE: kernel_package,
        }
      } else {
        {
          ...shared,
          LAPUTA_INSTALLER_QEMU_SMOKE: "1",
          LAPUTA_INSTALLER_QEMU_AUTHORIZED_KEY: authorized_key.display(),
          LAPUTA_INSTALLER_KERNEL_PACKAGE: kernel_package,
          LAPUTA_INSTALLER_KERNEL_SOURCE: kernel_source,
        }
      }
    }
  }
}

## Run one step of the installer pipeline. A failing child aborts this script
## with the child's own exit code, so make and nested scripts report the
## original status instead of a wrapped error; only a signaled child is an error.
export proc installer_run_argv(target: Path, argv: List[Str], cwd: Path, envs: Record = {}) [process, error] {
  let status = process.run(process.command_argv(target, argv, cwd, envs))?

  return when status.ok

  if status.exited() {
    exit status.exit_code()?
  }

  fail f"{argv[0]} was signaled"
}
