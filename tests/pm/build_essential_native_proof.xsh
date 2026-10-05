##! Behavior coverage for the build-essential-native typed-root proof contract.
pure runtime_packages() -> List[Str] {
  [
    "llvm-toolchain",
    "musl",
    "pkgconf",
    "samurai",
    "cmake",
    "m4",
    "flex",
    "bison",
    "linux",
    "muon",
  ]
}

proc runner() [process, env, error] -> Result[Path] {
  let configured = (e"XSH_HOST" ?? "").trim()

  return fp"{configured}" when configured != ""

  process.which("xsh")?
}

proc proof_root(ctx: TestContext, target: Str) [fs, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name: "build-essential-native-proof")?
  fs.mkdir(fp"{root}/usr/bin")
  fs.mkdir(fp"{root}/boot")

  for tool in [
    "cc",
    "c++",
    "pkg-config",
    "samu",
    "cmake",
    "m4",
    "flex",
    "bison",
    "muon",
  ] {
    fs.write(
      fp"{root}/usr/bin/{tool}",
      """typed proof fixture
""",
    )
  }

  fs.write(
    fp"{root}/boot/vmlinuz",
    """typed proof kernel fixture
""",
  )
  fs.mkdir(fp"{root}/var/lib/laputa")
  write_root_receipt(root, target, runtime_packages())
  root
}

proc write_root_receipt(root: Path, target: Str, packages: List[Str]) [fs, error] {
  json.write(
    fp"{root}/var/lib/laputa/root.json",
    {
      format: "laputa-root-1",
      target,
      artifacts: [
        {
          package_name: package,
          package_id: f"{package}-1-1",
          artifact_key: f"artifact-{package}",
          payload: true,
        }
        for package in packages
      ],
      entries: [],
      root_sha256: "typed-root-receipt",
    },
  )
}

# Proofs run with the build's XSH_PM_TARGET_ARCH, as in package-tools.
proc run_build_essential_proof(xsh: Path, arch: Str, root: Path, stderr: Path) [process, env, error] -> Result[Status] {
  env ({XSH_PM_TARGET_ARCH: arch}) {
    process.run(
      process.command_argv(
        xsh,
        [xsh, "packages/build-essential-native/proof.xsh", "--", root],
        stderr:,
      ),
    )?
  }
}

test test_build_essential_native_proof_uses_typed_root_receipt_without_legacy_db [fs, process, env, error] { |ctx|
  let xsh = runner()?

  for arch in ["aarch64", "x86_64"] {
    let target = f"{arch}-linux-musl"
    let root = proof_root(ctx, target)?
    let stderr = fp"{root}/proof.stderr"
    assert fs.exists(fp"{root}/var/lib/xsh-pm/packages")? == false
    assert run_build_essential_proof(xsh, arch, root, stderr)?.ok

    write_root_receipt(root, target, [package for package in runtime_packages() if package != "linux"])
    let missing = run_build_essential_proof(xsh, arch, root, stderr)?
    assert missing.ok == false
    assert "missing linux artifact in typed root receipt" in stderr.read_text()?
  }
}

test test_build_essential_native_proof_rejects_a_root_for_another_target [fs, process, env, error] { |ctx|
  let root = proof_root(ctx, "x86_64-linux-musl")?
  let stderr = fp"{root}/proof.stderr"
  let status = run_build_essential_proof(runner()?, "aarch64", root, stderr)?
  assert status.ok == false
  assert "invalid typed root receipt" in stderr.read_text()?
}
