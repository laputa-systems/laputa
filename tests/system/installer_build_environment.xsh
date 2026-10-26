use installer.host

test test_manual_installer_build_environment_with_and_without_kernel_source {
  let without_source = host.installer_build_environment(
    host.installer_manual_build_purpose(),
    fp"/tools/xsh",
    fp"/laputa",
    fp"/laputa/target/manual",
    fp"/laputa/target/manual/installer.iso",
    fp"/laputa/target/manual/kernel",
    null,
  )
  let with_source = host.installer_build_environment(
    host.installer_manual_build_purpose(),
    fp"/tools/xsh",
    fp"/laputa",
    fp"/laputa/target/manual",
    fp"/laputa/target/manual/installer.iso",
    fp"/laputa/target/manual/kernel",
    "/kernels/local.Image",
  )

  assert without_source.get("XSH_HOST")?.require(Str)? == "/tools/xsh"
  assert without_source.get("LAPUTA_ROOT")?.require(Str)? == "/laputa"
  assert without_source.get("LAPUTA_INSTALLER_WORK")?.require(Str)? == "/laputa/target/manual"
  assert without_source.get("LAPUTA_INSTALLER_ISO")?.require(Str)? == "/laputa/target/manual/installer.iso"
  assert without_source.get("LAPUTA_INSTALLER_KERNEL")?.require(Str)? == "/laputa/target/manual/kernel"
  assert without_source.get("LAPUTA_INSTALLER_CI")?.require(Str)? == "0"
  assert "LAPUTA_INSTALLER_QEMU_SMOKE" not in without_source.keys()
  assert "LAPUTA_INSTALLER_KERNEL_SOURCE" not in without_source.keys()
  assert with_source.get("XSH_HOST")?.require(Str)? == "/tools/xsh"
  assert with_source.get("LAPUTA_ROOT")?.require(Str)? == "/laputa"
  assert with_source.get("LAPUTA_INSTALLER_WORK")?.require(Str)? == "/laputa/target/manual"
  assert with_source.get("LAPUTA_INSTALLER_ISO")?.require(Str)? == "/laputa/target/manual/installer.iso"
  assert with_source.get("LAPUTA_INSTALLER_KERNEL")?.require(Str)? == "/laputa/target/manual/kernel"
  assert with_source.get("LAPUTA_INSTALLER_CI")?.require(Str)? == "0"
  assert with_source.get("LAPUTA_INSTALLER_KERNEL_SOURCE")?.require(Str)? == "/kernels/local.Image"
  assert "LAPUTA_INSTALLER_QEMU_SMOKE" not in with_source.keys()
}

test test_qemu_installer_build_environment_with_and_without_kernel_source {
  let without_source = host.installer_build_environment(
    host.installer_qemu_smoke_build_purpose(fp"/laputa/target/authorized_key", "linux-custom"),
    fp"/tools/xsh",
    fp"/laputa",
    fp"/laputa/target/qemu",
    fp"/laputa/target/qemu/installer.iso",
    fp"/laputa/target/qemu/kernel",
    null,
  )
  let with_source = host.installer_build_environment(
    host.installer_qemu_smoke_build_purpose(fp"/laputa/target/authorized_key", "linux-custom"),
    fp"/tools/xsh",
    fp"/laputa",
    fp"/laputa/target/qemu",
    fp"/laputa/target/qemu/installer.iso",
    fp"/laputa/target/qemu/kernel",
    "/kernels/local.bzImage",
  )

  assert without_source.get("XSH_HOST")?.require(Str)? == "/tools/xsh"
  assert without_source.get("LAPUTA_ROOT")?.require(Str)? == "/laputa"
  assert without_source.get("LAPUTA_INSTALLER_WORK")?.require(Str)? == "/laputa/target/qemu"
  assert without_source.get("LAPUTA_INSTALLER_ISO")?.require(Str)? == "/laputa/target/qemu/installer.iso"
  assert without_source.get("LAPUTA_INSTALLER_KERNEL")?.require(Str)? == "/laputa/target/qemu/kernel"
  assert without_source.get("LAPUTA_INSTALLER_QEMU_SMOKE")?.require(Str)? == "1"
  assert without_source.get("LAPUTA_INSTALLER_QEMU_AUTHORIZED_KEY")?.require(Str)? == "/laputa/target/authorized_key"
  assert without_source.get("LAPUTA_INSTALLER_KERNEL_PACKAGE")?.require(Str)? == "linux-custom"
  assert "LAPUTA_INSTALLER_CI" not in without_source.keys()
  assert "LAPUTA_INSTALLER_KERNEL_SOURCE" not in without_source.keys()
  assert with_source.get("XSH_HOST")?.require(Str)? == "/tools/xsh"
  assert with_source.get("LAPUTA_ROOT")?.require(Str)? == "/laputa"
  assert with_source.get("LAPUTA_INSTALLER_WORK")?.require(Str)? == "/laputa/target/qemu"
  assert with_source.get("LAPUTA_INSTALLER_ISO")?.require(Str)? == "/laputa/target/qemu/installer.iso"
  assert with_source.get("LAPUTA_INSTALLER_KERNEL")?.require(Str)? == "/laputa/target/qemu/kernel"
  assert with_source.get("LAPUTA_INSTALLER_QEMU_SMOKE")?.require(Str)? == "1"
  assert with_source.get("LAPUTA_INSTALLER_QEMU_AUTHORIZED_KEY")?.require(Str)? == "/laputa/target/authorized_key"
  assert with_source.get("LAPUTA_INSTALLER_KERNEL_PACKAGE")?.require(Str)? == "linux-custom"
  assert with_source.get("LAPUTA_INSTALLER_KERNEL_SOURCE")?.require(Str)? == "/kernels/local.bzImage"
  assert "LAPUTA_INSTALLER_CI" not in with_source.keys()
}
