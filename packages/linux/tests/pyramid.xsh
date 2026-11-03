use packages.linux.kbuild
use packages.linux.kbuild_verify
use packages.linux.PKGBUILD-shared as linux_shared

error PyramidStopError = Failed(message: Str)

proc pyramid_plan_archives(plan: kbuild.KbuildPlan, cache: Path) [fs, process, env, time, error] -> Result[kbuild.BuiltinArchivePlan] {
  env ({XSH_LINUX_KBUILD_PLAN_CACHE_DIR: cache.display(), XSH_LINUX_KBUILD_COMPILE_FLAGS_CACHE_DIR: cache.display(),
    XSH_LINUX_KBUILD_TRUST_COMPILE_FLAGS_CACHE: "0"}) {
    return kbuild.plan_builtin_archives(plan, p"/usr/bin/cc", "x86_64-linux-gnu", [], [], [])?
  }
}

proc pyramid_kernel_source(ctx: TestContext) [fs, env, time, process, error] -> Result[Path] {
  let source = test.temp_dir(ctx, name: "pyramid-kernel")?
  fp"{source}/.config".write("CONFIG_TEST=y\n")
  fp"{source}/include/generated".mkdir()
  fp"{source}/include/generated/autoconf.h".write("#define CONFIG_TEST 1\n")
  fp"{source}/Kbuild".write("obj-y += main.o\n")
  fp"{source}/main.c".write("int main(void) { return 0; }\n")
  let discovered = kbuild.discover_plan(source, kbuild.load_config(fp"{source}/.config")?, "x86")?
  assert [item.display() for item in discovered.dirs] == ["."]
  assert [item.display() for item in discovered.objects] == ["main.o"]
  assert discovered.unsupported == []
  kbuild.write_discovered_plan(discovered, fp"{source}/.xsh-kbuild-plan.json")
  let cache = test.temp_dir(ctx, name: "pyramid-kbuild-cache")?
  cd (source) {
    let planned = pyramid_plan_archives(discovered, cache)?
    assert planned.missing_sources == []
    assert planned.generated_objects == []
    assert planned.task_count == 2
    kbuild.write_archive_plan_report(planned, p".xsh-kbuild-archive-plan.json")
  }
  source
}

proc pyramid_stop(stage: kbuild_verify.LinuxKbuildStop) [env, error] -> Result[Unit, Error] {
  let requested = kbuild_verify.linux_kbuild_stop_name(stage)
  env ({XSH_LINUX_KBUILD_STOP_AFTER: requested}) {
    linux_shared.stop_after(requested)
  }
}

proc pyramid_reject_stop(stage: kbuild_verify.LinuxKbuildStop, outcome: Result[Unit, Error], source: Path) [fs, error] {
  match kbuild_verify.linux_kbuild_verify_stopped(stage, outcome, source) {
    Ok(_) => test.fail("invalid kernel stop passed verification")
    Err(_) => {}
  }
}

test test_pyramid_kernel_stop_requires_exact_kind_and_stage [fs, env, time, process, error] { |ctx|
  let source = pyramid_kernel_source(ctx)?
  match kbuild_verify.linux_kbuild_verify_stopped(kbuild_verify.Prepare, Err(PyramidStopError.Failed("original cause")), source) {
    Err(PyramidStopError.Failed {message}) => assert message == "original cause"
    else => test.fail("kernel stop verification lost the original error family")
  }
  for stage in [kbuild_verify.Prepare, kbuild_verify.Discover, kbuild_verify.Plan] {
    kbuild_verify.linux_kbuild_verify_stopped(stage, pyramid_stop(stage), source)
    pyramid_reject_stop(stage, Ok(), source)
    pyramid_reject_stop(stage, Err(kbuild.ScriptError.Failed(kind: "compiler-failed", message: f"stopped after {kbuild_verify.linux_kbuild_stop_name(stage)}")), source)
    pyramid_reject_stop(stage, Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-stopped", message: "stopped after link")), source)
  }
}

test test_pyramid_kernel_stop_requires_stage_artifacts [fs, env, time, process, error] { |ctx|
  let source = pyramid_kernel_source(ctx)?
  let archive_report = fp"{source}/.xsh-kbuild-archive-plan.json"
  let planned = kbuild.read_archive_plan_report(archive_report)?
  kbuild.write_archive_plan_report({...planned, tasks: [], task_count: 0}, archive_report)
  pyramid_reject_stop(kbuild_verify.Plan, pyramid_stop(kbuild_verify.Plan), source)
  kbuild.write_archive_plan_report({...planned, missing_sources: [p"missing.c"]}, archive_report)
  pyramid_reject_stop(kbuild_verify.Plan, pyramid_stop(kbuild_verify.Plan), source)
  archive_report.remove()
  pyramid_reject_stop(kbuild_verify.Plan, pyramid_stop(kbuild_verify.Plan), source)
  kbuild_verify.linux_kbuild_verify_stopped(kbuild_verify.Discover, pyramid_stop(kbuild_verify.Discover), source)
  fp"{source}/.xsh-kbuild-plan.json".write("corrupt plan\n")
  pyramid_reject_stop(kbuild_verify.Discover, pyramid_stop(kbuild_verify.Discover), source)
  kbuild_verify.linux_kbuild_verify_stopped(kbuild_verify.Prepare, pyramid_stop(kbuild_verify.Prepare), source)
  fp"{source}/include/generated/autoconf.h".write("")
  pyramid_reject_stop(kbuild_verify.Prepare, pyramid_stop(kbuild_verify.Prepare), source)
  fp"{source}/include/generated/autoconf.h".remove()
  pyramid_reject_stop(kbuild_verify.Prepare, pyramid_stop(kbuild_verify.Prepare), source)
}

test test_pyramid_kernel_stop_preserves_mismatched_error_context_and_cause [fs, error] {
  for kind in ["compiler-failed", "linux-kbuild-stopped"] {
    let original: Result[Unit, Error] = Err(
      kbuild.ScriptError.Failed(kind:, message: "stopped after link"),
      cause: PyramidStopError.Failed("compiler input unavailable"),
    ).context("kernel-scenario", "requested preparation")
    let observed = kbuild_verify.linux_kbuild_verify_stopped(kbuild_verify.Prepare, original, p"missing-kernel-source")
    assert observed == original
  }
}
