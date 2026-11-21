##! Recipe target policy and real recipe boundary behavior.
use pm.target
use pm.types
use pm.recipe

test typed_target_mappings_preserve_supported_abis [error] {
  let arm = target.lp64_musl_abi(types.Aarch64LinuxMusl)?
  let x86 = target.lp64_musl_abi(types.X86_64LinuxMusl)?
  assert arm.arch == "aarch64"
  assert x86.arch == "x86_64"
  assert ! arm.signed_wchar_t
  assert x86.signed_wchar_t
  assert arm.wchar_t_suffix == "\"UINT\""
  assert x86.wchar_t_suffix == "\"INT\""
  for abi in [arm, x86] {
    assert abi.ptrdiff_bits == "64"
    assert abi.size_t_bits == "64"
    assert abi.sig_atomic_bits == "32"
    assert abi.wchar_t_bits == "32"
    assert abi.wint_t_bits == "32"
    assert abi.ptrdiff_suffix == "\"L\""
    assert abi.size_t_suffix == "\"UL\""
    assert abi.sig_atomic_suffix == "\"INT\""
    assert abi.wint_t_suffix == "\"UINT\""
    assert abi.signed_sig_atomic_t
  }
  assert target.rust_triple(types.Aarch64LinuxMusl)? == "aarch64-unknown-linux-musl"
  assert target.rust_triple(types.X86_64LinuxMusl)? == "x86_64-unknown-linux-musl"
  assert target.kernel_arch(types.Aarch64LinuxMusl)? == "arm64"
  assert target.kernel_arch(types.X86_64LinuxMusl)? == "x86"
}

test typed_target_rejects_reserved_and_unknown_targets [env, error] {
  match target.lp64_musl_abi(types.TargetReserved) {
    Ok(_) => test.fail("reserved target received a musl ABI")
    Err(problem) => assert "unsupported" in problem.message
  }
  match target.rust_triple(types.TargetReserved) {
    Ok(_) => test.fail("reserved target received a Rust triple")
    Err(problem) => assert "unsupported" in problem.message
  }
  match target.kernel_arch(types.TargetReserved) {
    Ok(_) => test.fail("reserved target received a kernel architecture")
    Err(problem) => assert "unsupported" in problem.message
  }
  env ({XSH_PM_TARGET_ARCH: "riscv64"}) {
    match target.recipe_target() {
      Ok(_) => test.fail("unsupported recipe target was accepted")
      Err(problem) => assert "unsupported target riscv64" in problem.message
    }
  }
  env ({XSH_PM_BUILD_ARCH: "riscv64"}) {
    match target.build_target() {
      Ok(_) => test.fail("unsupported build target was accepted")
      Err(problem) => assert "unsupported target riscv64" in problem.message
    }
  }
}

test actual_recipes_reject_unsupported_target_before_building [fs, process, env, error] { |ctx|
  let dest = test.temp_dir(ctx, name: "unsupported-recipe-target")?
  let root = fs.cwd()?
  let tools = test.temp_dir(ctx, name: "unsupported-recipe-tools")?
  fp"{tools}/cc".write("#!/bin/sh\necho 'cc ran before the target was rejected' >&2\nexit 1\n", mode: 0o755)
  for name in ["bison", "libffi", "musl", "perf", "strace"] {
    let dir = fp"{root}/packages/{name}"
    let pkg = recipe.load_package_for_target(dir, types.Aarch64LinuxMusl)?
    env ({XSH_PM_TARGET_ARCH: "riscv64", PATH: f"{tools}:{e"PATH" ?? ""}"}) {
      match recipe.call_build(pkg, dir, dest) {
        Ok(_) => test.fail(f"{name} accepted unsupported target")
        Err(problem) => assert "unsupported target riscv64" in problem.message, f"{name}: {problem.message}"
      }
    }
  }
}

test actual_proofs_reject_unknown_targets_before_payload_access [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "unsupported-proof-target")?
  for name in ["linux", "linux-headers", "musl", "llvm-toolchain"] {
    let source = fp"packages/{name}/proof.xsh".read_text()?
    let result = test.run_xsh(ctx, source, [], [root.display()], {XSH_PM_TARGET_ARCH: "riscv64"}, name: f"{name}-unsupported-proof.xsh")?
    assert ! result.success, f"{name} accepted unsupported target"
    assert "unsupported target riscv64" in result.stderr, f"{name}: {result.stderr}"
  }
}
