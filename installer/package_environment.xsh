##! Typed environment values for installer package-manager subprocesses.

## Repository and target configuration required by each installer package invocation.
export type PackageEnvironment = {
  XSH_MODULE_PATH: Str,
  XSH_PM_REPO: Str,
  XSH_PM_PUBLIC_REPO: Str,
  XSH_PM_ARCH: Str,
}

## Package invocations with an explicit smoke flag also carry its string value.
export type SmokePackageEnvironment = {
  XSH_MODULE_PATH: Str,
  XSH_PM_REPO: Str,
  XSH_PM_PUBLIC_REPO: Str,
  XSH_PM_ARCH: Str,
  LAPUTA_INSTALLER_QEMU_SMOKE: Str,
}

## Construct the repository environment without supplying an installer smoke flag.
export pure environment(packages_root: Path, repo_url: Str, arch: Str) -> PackageEnvironment {
  PackageEnvironment(
    XSH_MODULE_PATH: packages_root.display(),
    XSH_PM_REPO: repo_url,
    XSH_PM_PUBLIC_REPO: repo_url,
    XSH_PM_ARCH: arch,
  )
}

## Construct a package environment with an explicit installer smoke flag.
export pure smoke_environment(packages_root: Path, repo_url: Str, arch: Str, qemu_smoke: Str) -> SmokePackageEnvironment {
  SmokePackageEnvironment(...environment(packages_root, repo_url, arch), LAPUTA_INSTALLER_QEMU_SMOKE: qemu_smoke)
}
