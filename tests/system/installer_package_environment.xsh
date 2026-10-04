##! Installer package subprocess environments retain typed values and explicit smoke configuration.
use installer.package_environment

test test_installer_package_environment_keeps_required_repository_values [error] {
  let values = package_environment.environment(/work/packages, "https://packages.example.test", "aarch64")
  assert values.XSH_MODULE_PATH == "/work/packages"
  assert values.XSH_PM_REPO == "https://packages.example.test"
  assert values.XSH_PM_PUBLIC_REPO == "https://packages.example.test"
  assert values.XSH_PM_ARCH == "aarch64"
  assert "LAPUTA_INSTALLER_QEMU_SMOKE" not in values
}

test test_installer_package_environment_only_adds_explicit_smoke_configuration [error] {
  for smoke in ["0", "1"] {
    let values = package_environment.smoke_environment(/work/packages, "file:///repository", "x86_64", smoke)
    assert values.XSH_PM_REPO == "file:///repository"
    assert values.XSH_PM_ARCH == "x86_64"
    assert values.LAPUTA_INSTALLER_QEMU_SMOKE == smoke
  }
}

test test_installer_package_environment_crosses_the_process_boundary [fs, process, error] { |ctx|
  let root = test.temp_dir(ctx, name: "installer-package-environment")?
  let output = fp"${root}/environment.txt"
  let command = process.command_argv(
    /usr/bin/env,
    ["env"],
    env: package_environment.environment(/work/packages, "file:///repository", "aarch64"),
    stdout: output,
  )
  assert process.run(command)?.ok
  let text = fs.read_text(output)?
  assert "XSH_PM_REPO=file:///repository" in text
  assert "XSH_PM_ARCH=aarch64" in text

  let smoke_command = process.command_argv(
    /usr/bin/env,
    ["env"],
    env: package_environment.smoke_environment(/work/packages, "file:///repository", "aarch64", "0"),
    stdout: output,
  )
  assert process.run(smoke_command)?.ok
  assert "LAPUTA_INSTALLER_QEMU_SMOKE=0" in fs.read_text(output)?
}
