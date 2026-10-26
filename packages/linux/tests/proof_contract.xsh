##! Kernel proof acceptance and rejection at the installed-payload boundary.
use packages.upstream_pins

test test_linux_proof_checks_versioned_images_architecture_and_bzimage_headers [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-proof-contract")?
  fp"{root}/boot".mkdir()
  fp"{root}/usr/share/linux".mkdir()
  let image = bytes.concat([
    bytes.from_text("MZ"),
    bytes.from_ints([0 for index in range(512)])?,
    bytes.from_text("HdrS"),
  ])
  let source = p"packages/linux/proof.xsh".read_text()?
  for case in [
    {arch: "x86_64", config: "CONFIG_X86_64=y\n", image, accepted: true, diagnostic: ""},
    {arch: "x86_64", config: "CONFIG_ARM64=y\n", image, accepted: false, diagnostic: "expected CONFIG_X86_64=y"},
    {arch: "x86_64", config: "CONFIG_X86_64=y\n", image: bytes.from_ints([0 for index in range(518)])?, accepted: false, diagnostic: "missing MZ header"},
    {arch: "x86_64", config: "CONFIG_X86_64=y\n", image: bytes.concat([bytes.from_text("MZ"), bytes.from_ints([0 for index in range(516)])?]), accepted: false, diagnostic: "missing HdrS setup header"},
    {arch: "aarch64", config: "CONFIG_ARM64=y\n", image: bytes.from_text("arm64 kernel"), accepted: true, diagnostic: ""},
    {arch: "aarch64", config: "CONFIG_X86_64=y\n", image, accepted: false, diagnostic: "expected CONFIG_ARM64=y"},
    {arch: "riscv64", config: "CONFIG_RISCV=y\n", image, accepted: false, diagnostic: "unsupported proof arch"},
  ] {
    fp"{root}/boot/vmlinuz".write(case.image)
    fp"{root}/boot/vmlinuz-{upstream_pins.linux_kernel_version}".write(case.image)
    fp"{root}/usr/share/linux/config-{upstream_pins.linux_kernel_version}".write(case.config)
    let result = test.run_xsh(ctx, source, [], [root.display()], {XSH_PM_TARGET_ARCH: case.arch}, name: "linux-proof.xsh")?
    assert result.success == case.accepted, result.stderr
    if case.accepted {
      assert "linux ok: vmlinuz" in result.stdout
    } else {
      assert case.diagnostic in result.stderr, result.stderr
    }
  }
  fp"{root}/boot/vmlinuz-{upstream_pins.linux_kernel_version}".remove()
  let missing = test.run_xsh(ctx, source, [], [root.display()], {XSH_PM_TARGET_ARCH: "x86_64"}, name: "linux-proof-missing.xsh")?
  assert ! missing.success
  assert "missing versioned kernel image" in missing.stderr, missing.stderr
}
