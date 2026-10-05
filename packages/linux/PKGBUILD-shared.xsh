##! XSH module `PKGBUILD-shared` package and build operations.
use kbuild
use pm.make

## Exported declaration `build_jobs`.
export proc build_jobs() [env, error] -> Result[Int, Error] {
  let raw = e"XSH_LINUX_KBUILD_JOBS" ?? ""

  if raw != "" {
    let parsed = raw as Int

    if parsed <= 0 {
      return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-jobs", message: "XSH_LINUX_KBUILD_JOBS must be a positive integer"))
    }

    return parsed
  }

  make.jobs()
}

## Exported declaration `archive_analysis_jobs`.
export proc archive_analysis_jobs() [env, error] -> Result[Int, Error] {
  let raw = e"XSH_LINUX_KBUILD_ARCHIVE_ANALYSIS_JOBS" ?? ""

  return 8 when raw == ""

  let parsed = raw as Int

  if parsed <= 0 {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-kbuild-archive-analysis-jobs",
        message: "XSH_LINUX_KBUILD_ARCHIVE_ANALYSIS_JOBS must be a positive integer",
      ),
    )
  }

  parsed
}

## Exported declaration `discover_options_from_env`.
export proc discover_options_from_env() [env, error] -> Result[kbuild.DiscoverOptions, Error] {
  let every_text = e"XSH_LINUX_KBUILD_PROGRESS_EVERY" ?? "100"
  let jobs_text = e"XSH_LINUX_KBUILD_DISCOVER_JOBS" ?? ""
  let jobs_count = if jobs_text == "" { build_jobs()? } else { jobs_text as Int }

  {
    progress: (e"XSH_LINUX_KBUILD_PROGRESS" ?? "") == "1",
    progress_every: every_text as Int,
    jobs: jobs_count,
    local_records: (e"XSH_LINUX_KBUILD_LOCAL_RECORDS" ?? "") == "1",
    local_record_cache: (e"XSH_LINUX_KBUILD_LOCAL_RECORD_CACHE" ?? "") == "1" and (e"XSH_LINUX_KBUILD_FORCE_DISCOVER" ?? "") != "1",
    build_plan: true,
  }
}

# Kbuild workers are recipe programs, not source-tree files.  The executor
# copies the complete typed recipe into XSH_PM_RECIPE_DIR, whose .xsh inputs are
# fingerprinted with the package build input; resolving from ../pkg silently
# depended on a legacy staging layout that no longer exists.
proc staged_recipe_helper(name: Str) -> Result[Path] {
  let recipe_dir = (e"XSH_PM_RECIPE_DIR" ?? "").trim()

  if recipe_dir == "" {
    return Err(kbuild.ScriptError.Failed(kind: "linux-recipe-helper", message: f"missing XSH_PM_RECIPE_DIR for {name}"))
  }

  let helper = fp"{recipe_dir}/{name}"

  if ! helper.exists() {
    return Err(kbuild.ScriptError.Failed(kind: "linux-recipe-helper", message: f"missing staged recipe helper: {helper}"))
  }

  helper
}

## Exported declaration `discover_package_plan`.
export proc discover_package_plan(srcarch: Str) [fs, process, env, time, error] -> Result[kbuild.KbuildPlan, Error] {
  let config = kbuild.load_config(p".config")?
  let options = discover_options_from_env()?

  if ! options.local_record_cache {
    let xsh_bin = process.which("xsh")?
    let worker = staged_recipe_helper("kbuild-pool-worker.xsh")?
    return kbuild.discover_plan_with_process_pool(
      p".",
      p".config",
      srcarch,
      options,
      xsh_bin,
      worker,
    )?
  }

  kbuild.discover_plan_with_options(p".", config, srcarch, options)?
}

## Exported declaration `write_materialized_outputs`.
export proc write_materialized_outputs(outputs: List[Path]) [fs, error] {
  var text = """format linux-materialized-outputs-v1
"""

  for output in outputs {
    text = f"""{text}{output}
"""
  }

  kbuild.write_text_if_changed(p".xsh-kbuild/materialized-outputs", text)
}

## Exported declaration `requested_stop_after`.
export proc requested_stop_after() [env, error] -> Result[Str, Error] {
  let requested = e"XSH_LINUX_KBUILD_STOP_AFTER" ?? ""

  return "" when requested == ""

  if requested not in ["prepare", "discover", "plan", "compile", "link"] {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-kbuild-stop-after",
        message: f"XSH_LINUX_KBUILD_STOP_AFTER must be prepare, discover, plan, compile, or link; got '{requested}'",
      ),
    )
  }

  requested
}

## Exported declaration `stop_after`.
export proc stop_after(stage: Str) [env, error] {
  if requested_stop_after()? == stage {
    return Err(kbuild.ScriptError.Failed(kind: "linux-kbuild-stopped", message: f"stopped after {stage}"))
  }
}

## Exported declaration `timing_start`.
export proc timing_start(stage: Str) [env, time] -> Int {
  if (e"XSH_LINUX_KBUILD_TIMING" ?? "") == "1" {
    print "linux-kbuild-timing-start" $stage
    return time.now()
  }

  0
}

## Exported declaration `timing_done`.
export proc timing_done(stage: Str, start: Int) [env, time] {
  if (e"XSH_LINUX_KBUILD_TIMING" ?? "") == "1" {
    let elapsed = time.now() - start
    print "linux-kbuild-timing-done" $stage $elapsed "ms"
  }
}

## Exported declaration `emit_plan_if_enabled`.
export proc emit_plan_if_enabled(plan: kbuild.KbuildPlan) [fs, env, error] {
  if (e"XSH_LINUX_KBUILD_PLAN" ?? "") == "1" {
    kbuild.write_discovered_plan(plan, p".xsh-kbuild-plan.json")
    print "xsh-kbuild-plan" plan.dirs.len() "dirs" plan.objects.len() "objects" plan.unsupported.len() "unsupported"
  }
}

## Exported declaration `emit_kbuild_progress`.
export proc emit_kbuild_progress(message: Str) [fs, env, error] {
  if (e"XSH_LINUX_KBUILD_PROGRESS" ?? "") == "1" {
    kbuild.write_text_if_changed(
      p".xsh-kbuild-progress",
      f"""{message}
""",
    )

    print $message
  }
}

proc remove_archive_plan_cache() {
  p".xsh-kbuild-archive-plan.json".remove(missing_ok: true)
  p".xsh-kbuild-archive-plan.json.summary".remove(missing_ok: true)
  p".xsh-kbuild-archive-plan.fingerprint".remove(missing_ok: true)
}

proc archive_plan_cache_fingerprint(
  plan: kbuild.KbuildPlan,
  srcarch: Str,
  triple: Str,
  cflags: List[Str],
  includes: List[Str],
) -> Result[Str] {
  f"""format linux-archive-plan-cache-v1
srcarch {srcarch}
triple {triple}
plan
{kbuild.plan_fingerprint(p".", p".config", plan)?}
cflags
{cflags.join("\n")}
includes
{includes.join("\n")}
"""
}

proc archive_plan_fingerprint_matches(path_value: Path, fingerprint: Str) -> Result[Bool] {
  guard path_value.exists() else {
    return false
  }

  path_value.read_text()?.trim() == fingerprint.trim()
}

proc write_archive_plan_fingerprint(path_value: Path, fingerprint: Str) {
  kbuild.write_text_if_changed(
    path_value,
    f"""{fingerprint}
""",
  )
}

proc copy_archive_plan_cache(source: Path, dest: Path) {
  guard source.exists() else {
    return
  }

  fs.install(source, dest, 0o644, parents: true, overwrite: true)
  let source_summary = kbuild.archive_plan_summary_path(source)

  if source_summary.exists() {
    fs.install(source_summary, kbuild.archive_plan_summary_path(dest), 0o644, parents: true, overwrite: true)
  }
}

## Exported declaration `cached_archive_plan`.
export proc cached_archive_plan(
  plan: kbuild.KbuildPlan,
  cc: Path,
  srcarch: Str,
  triple: Str,
  cflags: List[Str],
  includes: List[Str],
) [fs, process, env, time, error] -> Result[kbuild.BuiltinArchivePlan, Error] {
  if srcarch != "arm64" and srcarch != "x86" {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-native-kbuild-unsupported-arch",
        message: f"native scratch Kbuild final link is only implemented for arm64 and x86; {srcarch} needs new arch support",
      ),
    )
  }

  let archive_report = p".xsh-kbuild-archive-plan.json"
  let archive_fingerprint = p".xsh-kbuild-archive-plan.fingerprint"
  let stable_cache_dir = fp"{e"XSH_LINUX_KBUILD_PLAN_CACHE_DIR" ?? "/var/cache/laputa/linux-kbuild"}"
  let stable_archive_report = fp"{stable_cache_dir}/linux-{srcarch}.archive-plan.json"
  let stable_archive_fingerprint = fp"{stable_cache_dir}/linux-{srcarch}.archive-plan.fingerprint"
  let fingerprint_start = timing_start("archive-fingerprint")
  let fingerprint = archive_plan_cache_fingerprint(plan, srcarch, triple, cflags, includes)?
  timing_done("archive-fingerprint", fingerprint_start)
  let reuse_archive_plan = (e"XSH_LINUX_KBUILD_REUSE_ARCHIVE_PLAN" ?? "") == "1"
  let archive_only = (e"XSH_LINUX_KBUILD_ARCHIVE_ONLY" ?? "") == "1"
  let plan_only = requested_stop_after()? == "plan" and (e"XSH_LINUX_KBUILD_ONLY" ?? "") == ""

  if reuse_archive_plan and (e"XSH_LINUX_KBUILD_FORCE_ARCHIVES" ?? "") != "1" {
    if archive_report.exists() and archive_plan_fingerprint_matches(archive_fingerprint, fingerprint) {
      if plan_only {
        match kbuild.read_archive_plan_summary(kbuild.archive_plan_summary_path(archive_report)) {
          Ok(archive_plan) => {
            emit_kbuild_progress(
              f"xsh-kbuild-archive-plan-summary-cache {archive_plan.task_count} tasks {archive_plan.archives.len()} archives {archive_plan.link_inputs.len()} link-inputs",
            )

            return archive_plan
          }
          Err(error) => emit_kbuild_progress(
            f"xsh-kbuild-archive-plan-summary-cache miss {error.message}",
          )
        }
      }

      match kbuild.read_archive_plan_report(archive_report) {
        Ok(archive_plan) => {
          emit_kbuild_progress(
            f"xsh-kbuild-archive-plan-cache {archive_plan.tasks.len()} tasks {archive_plan.archives.len()} archives {archive_plan.link_inputs.len()} link-inputs",
          )

          if plan_only {
            kbuild.write_archive_plan_summary(archive_plan, kbuild.archive_plan_summary_path(archive_report))
          }

          return archive_plan
        }
        Err(error) => emit_kbuild_progress(
          f"xsh-kbuild-archive-plan-cache miss {error.message}",
        )
      }
    }

    if stable_archive_report.exists() and archive_plan_fingerprint_matches(stable_archive_fingerprint, fingerprint) {
      if plan_only {
        match kbuild.read_archive_plan_summary(kbuild.archive_plan_summary_path(stable_archive_report)) {
          Ok(archive_plan) => {
            emit_kbuild_progress(
              f"xsh-kbuild-archive-plan-stable-summary-cache {archive_plan.task_count} tasks {archive_plan.archives.len()} archives {archive_plan.link_inputs.len()} link-inputs",
            )

            copy_archive_plan_cache(stable_archive_report, archive_report)
            write_archive_plan_fingerprint(archive_fingerprint, fingerprint)
            return archive_plan
          }
          Err(error) => emit_kbuild_progress(
            f"xsh-kbuild-archive-plan-stable-summary-cache miss {error.message}",
          )
        }
      }

      match kbuild.read_archive_plan_report(stable_archive_report) {
        Ok(archive_plan) => {
          emit_kbuild_progress(
            f"xsh-kbuild-archive-plan-stable-cache {archive_plan.tasks.len()} tasks {archive_plan.archives.len()} archives {archive_plan.link_inputs.len()} link-inputs",
          )

          copy_archive_plan_cache(stable_archive_report, archive_report)
          write_archive_plan_fingerprint(archive_fingerprint, fingerprint)
          return archive_plan
        }
        Err(error) => emit_kbuild_progress(
          f"xsh-kbuild-archive-plan-stable-cache miss {error.message}",
        )
      }
    }
  }

  emit_kbuild_progress(
    f"xsh-kbuild-archive-plan-start {plan.dirs.len()} dirs {plan.objects.len()} objects {plan.composites.len()} composites",
  )

  let analysis_jobs = archive_analysis_jobs()?
  let worker = staged_recipe_helper("kbuild-archive-analysis-worker.xsh")?
  let archive_plan = kbuild.plan_builtin_archives_with_analysis_workers(
    plan,
    cc,
    triple,
    cflags,
    [],
    includes,
    analysis_jobs,
    /bin/xsh,
    worker,
  )?

  if archive_only {
    emit_kbuild_progress(
      f"xsh-kbuild-archive-plan {archive_plan.task_count} tasks {archive_plan.archives.len()} archives {archive_plan.link_inputs.len()} link-inputs {archive_plan.generated_objects.len()} generated {archive_plan.missing_sources.len()} missing",
    )
    return archive_plan
  }

  let report_start = timing_start("archive-report")
  kbuild.write_archive_plan_report(archive_plan, archive_report)
  write_archive_plan_fingerprint(archive_fingerprint, fingerprint)
  stable_cache_dir.mkdir()
  copy_archive_plan_cache(archive_report, stable_archive_report)
  write_archive_plan_fingerprint(stable_archive_fingerprint, fingerprint)
  timing_done("archive-report", report_start)

  emit_kbuild_progress(
    f"xsh-kbuild-archive-plan {archive_plan.task_count} tasks {archive_plan.archives.len()} archives {archive_plan.link_inputs.len()} link-inputs {archive_plan.generated_objects.len()} generated {archive_plan.missing_sources.len()} missing",
  )

  archive_plan
}

# A cached plan is used only when its fingerprint (the .config and the
# kernel release) still matches; anything else rediscovers the whole plan,
# which takes about a second. Patching a stale plan for a few known config
# symbols would silently miss every other config change.
## Exported declaration `cached_package_plan`.
export proc cached_package_plan(srcarch: Str) [fs, process, env, time, error] -> Result[kbuild.KbuildPlan, Error] {
  let config = kbuild.load_config(p".config")?
  let explicit_inline = e"XSH_LINUX_KBUILD_USE_PLAN_TEXT_INLINE" ?? ""
  let explicit_text = e"XSH_LINUX_KBUILD_USE_PLAN_TEXT" ?? ""
  let explicit = e"XSH_LINUX_KBUILD_USE_PLAN" ?? ""

  if explicit_inline != "" {
    emit_kbuild_progress("xsh-kbuild-plan-cache explicit-inline-read")
    let plan = kbuild.parse_discovered_plan_text(explicit_inline)?
    print "xsh-kbuild-plan-cache" "explicit-inline" plan.dirs.len() "dirs" plan.objects.len() "objects" plan.composites.len() "composites"
    return plan
  }

  if explicit_text != "" {
    emit_kbuild_progress(f"xsh-kbuild-plan-cache explicit-text-read {explicit_text}")
    let plan = kbuild.read_discovered_plan_text(fp"{explicit_text}")?
    print "xsh-kbuild-plan-cache" "explicit-text" $explicit_text plan.dirs.len() "dirs" plan.objects.len() "objects" plan.composites.len() "composites"
    return plan
  }

  if explicit != "" {
    emit_kbuild_progress(f"xsh-kbuild-plan-cache explicit-read {explicit}")
    let plan = kbuild.read_discovered_plan(fp"{explicit}")?
    print "xsh-kbuild-plan-cache" "explicit" $explicit plan.dirs.len() "dirs" plan.objects.len() "objects" plan.composites.len() "composites"
    return plan
  }

  let force_discover = (e"XSH_LINUX_KBUILD_FORCE_DISCOVER" ?? "") == "1"
  let plan_path = p".xsh-kbuild-plan.json"
  let fingerprint_path = p".xsh-kbuild-plan.fingerprint"
  let stable_cache_dir = fp"{e"XSH_LINUX_KBUILD_PLAN_CACHE_DIR" ?? "/var/cache/laputa/linux-kbuild"}"
  let stable_plan_path = fp"{stable_cache_dir}/linux-{srcarch}.plan.json"
  let stable_fingerprint_path = fp"{stable_cache_dir}/linux-{srcarch}.plan.fingerprint"

  if force_discover {
    emit_kbuild_progress("xsh-kbuild-plan-cache force-discover")
  }

  if ! force_discover and plan_path.exists() and fingerprint_path.exists() {
    emit_kbuild_progress("xsh-kbuild-plan-cache read")
    let plan = kbuild.read_discovered_plan(plan_path)?
    emit_kbuild_progress(f"xsh-kbuild-plan-cache fingerprint {plan.dirs.len()} dirs {plan.objects.len()} objects")

    if (e"XSH_LINUX_KBUILD_TRUST_PLAN_CACHE" ?? "") == "1" {
      print "xsh-kbuild-plan-cache" "trusted" plan.dirs.len() "dirs" plan.objects.len() "objects" plan.composites.len() "composites"
      return plan
    }

    let fingerprint = kbuild.plan_fingerprint(p".", p".config", plan)?

    if fingerprint_path.read_text()?.trim() == fingerprint.trim() {
      print "xsh-kbuild-plan-cache" "hit" plan.dirs.len() "dirs" plan.objects.len() "objects" plan.composites.len() "composites"
      return plan
    }

    if stable_plan_path.exists() and stable_fingerprint_path.exists() {
      emit_kbuild_progress("xsh-kbuild-plan-cache stale-stable-read")
      let stable_plan = kbuild.read_discovered_plan(stable_plan_path)?
      let stable_fingerprint = kbuild.plan_fingerprint(p".", p".config", stable_plan)?

      if stable_fingerprint_path.read_text()?.trim() == stable_fingerprint.trim() {
        kbuild.write_discovered_plan(stable_plan, plan_path)

        kbuild.write_text_if_changed(
          fingerprint_path,
          f"""{stable_fingerprint}
""",
        )

        print "xsh-kbuild-plan-cache" "stale-stable-hit" stable_plan.dirs.len() "dirs" stable_plan.objects.len() "objects" stable_plan.composites.len() "composites"
        return stable_plan
      }
    }

    emit_kbuild_progress("xsh-kbuild-plan-cache stale")
  }

  if ! force_discover and stable_plan_path.exists() and stable_fingerprint_path.exists() {
    emit_kbuild_progress("xsh-kbuild-plan-cache stable-read")
    let stable_plan = kbuild.read_discovered_plan(stable_plan_path)?
    let stable_fingerprint = kbuild.plan_fingerprint(p".", p".config", stable_plan)?

    if stable_fingerprint_path.read_text()?.trim() == stable_fingerprint.trim() {
      kbuild.write_discovered_plan(stable_plan, plan_path)

      kbuild.write_text_if_changed(
        fingerprint_path,
        f"""{stable_fingerprint}
""",
      )

      print "xsh-kbuild-plan-cache" "stable-hit" stable_plan.dirs.len() "dirs" stable_plan.objects.len() "objects" stable_plan.composites.len() "composites"
      return stable_plan
    }

    emit_kbuild_progress("xsh-kbuild-plan-cache stable-miss")
  }

  emit_kbuild_progress("xsh-kbuild-plan discover-start")
  let plan = discover_package_plan(srcarch)?
  emit_kbuild_progress(f"xsh-kbuild-plan write {plan.dirs.len()} dirs {plan.objects.len()} objects")
  kbuild.write_discovered_plan(plan, plan_path)
  remove_archive_plan_cache()
  emit_kbuild_progress("xsh-kbuild-plan fingerprint")
  let fingerprint = kbuild.plan_fingerprint(p".", p".config", plan)?

  kbuild.write_text_if_changed(
    fingerprint_path,
    f"""{fingerprint}
""",
  )

  stable_cache_dir.mkdir()
  kbuild.write_discovered_plan(plan, stable_plan_path)

  kbuild.write_text_if_changed(
    stable_fingerprint_path,
    f"""{fingerprint}
""",
  )

  emit_plan_if_enabled(plan)
  plan
}

## Exported declaration `add_extra_objects_from_env`.
export proc add_extra_objects_from_env(plan: kbuild.KbuildPlan) [env, error] -> Result[kbuild.KbuildPlan, Error] {
  let raw = (e"XSH_LINUX_KBUILD_EXTRA_OBJECTS" ?? "").replace(",", " ")
  var objects = [fp"{item}" for item in raw.words()]
  kbuild.add_plan_objects(plan, objects)
}

proc parse_kbuild_only_outputs(raw: Str) [error] -> Result[List[Path]] {
  var outputs: List[Path] = []

  for item in raw.split(",") {
    let trimmed = item.trim()

    if trimmed != "" {
      outputs += [fp"{trimmed}"]
    }
  }

  if outputs.is_empty() {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-native-kbuild-target-empty",
        message: "XSH_LINUX_KBUILD_ONLY must name at least one archive-plan output",
      ),
    )
  }

  outputs
}

## Exported declaration `run_targeted_kbuild_outputs`.
export proc run_targeted_kbuild_outputs(
  archive_plan: kbuild.BuiltinArchivePlan,
  only: Str,
) [fs, process, env, time, error] {
  let outputs = parse_kbuild_only_outputs(only)?
  let jobs_count = build_jobs()?
  let selected = kbuild.select_archive_tasks_outputs(archive_plan.tasks, outputs)?
  print "linux-native-kbuild-target-plan" selected.len() "tasks" outputs.len() "outputs"

  if requested_stop_after()? == "plan" {
    kbuild.write_archive_plan_report(archive_plan, p".xsh-kbuild-archive-plan.json")
    stop_after("plan")
  }

  make.run_tasks(selected, jobs_count)
  stop_after("compile")

  return Err(
    kbuild.ScriptError.Failed(
      kind: "linux-native-kbuild-target-complete",
      message: f"native scratch Kbuild ran outputs.len() requested target(s); continue with the next targeted object batch or the full archive graph",
    ),
  )
}

## Exported declaration `require_valid_archive_plan`.
export proc require_valid_archive_plan(archive_plan: kbuild.BuiltinArchivePlan) [error] {
  if ! archive_plan.duplicate_outputs.is_empty() {
    return Err(kbuild.ScriptError.Failed(kind: "linux-native-kbuild-duplicate-output", message: "archive plan has duplicate output"))
  }

  var outputs: Map[Bool] = {}

  for task in archive_plan.tasks {
    for output in task.outputs {
      let key = output.display()
      continue when key == ""

      if outputs.get(key) ?? false {
        return Err(
          kbuild.ScriptError.Failed(kind: "linux-native-kbuild-duplicate-output", message: "archive plan has duplicate output"),
        )
      }

      outputs[key] = true
    }
  }
}

## Exported declaration `require_complete_x86_archive_plan`.
export proc require_complete_x86_archive_plan(archive_plan: kbuild.BuiltinArchivePlan) [error] {
  require_valid_archive_plan(archive_plan)

  if ! archive_plan.generated_objects.is_empty() {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-native-kbuild-generated-incomplete",
        message: f"x86 full package build still has {archive_plan.generated_objects.len()} generated object(s); generate or exclude them before linking",
      ),
    )
  }

  if ! archive_plan.missing_sources.is_empty() {
    return Err(
      kbuild.ScriptError.Failed(
        kind: "linux-native-kbuild-missing-sources",
        message: f"x86 full package build still has {archive_plan.missing_sources.len()} selected object(s) without direct sources; restore/generate/exclude them before linking",
      ),
    )
  }
}

## Exported declaration `native_tool`.
export proc native_tool(name: Str) [fs, process, env, error] -> Result[Path, Error] {
  let build_root = e"XSH_PM_BUILD_ROOT" ?? ""

  if build_root != "" {
    let tool = fp"{build_root}/usr/bin/{name}"

    return tool when tool.exists()
  }

  process.which(name)?
}

## Exported declaration `run_native_command`.
export proc run_native_command(argv: List[Str]) [process, env, error] {
  let build_root = e"XSH_PM_BUILD_ROOT" ?? ""

  let command = if build_root != "" {
    process.command_argv(argv[0], argv, env: {PATH: f"{build_root}/usr/bin:{e"PATH" ?? ""}"})
  } else {
    process.command_argv(argv[0], argv)
  }

  let status = process.run(command)?

  if ! status.ok {
    return Err(kbuild.ScriptError.Failed(kind: "linux-native-kbuild-command", message: f"command failed: {argv.join(" ")}"))
  }
}

## Exported declaration `write_default_builtin_initramfs`.
export proc write_default_builtin_initramfs(cc: Path) [fs, process, env, error] {
  # Keep Linux's default built-in cpio, not a userspace initramfs. With
  # CONFIG_INITRAMFS_SOURCE="", upstream kbuild generates usr/default_cpio_list:
  # /dev, /dev/console, and /root. Those entries are enough for the kernel's
  # no-initramfs block-root path to create /dev/root before mounting the real
  # ext4 root, where xinit then runs as /init.
  #
  # The XSH native Kbuild path does not run usr/Makefile, so we must explicitly
  # generate the same usr/initramfs_inc_data payload here. Writing an empty file
  # regresses direct block-root boot with "Failed to create /dev/root".
  p".xsh-kbuild/host".mkdir()
  let gen = p".xsh-kbuild/host/gen_init_cpio"
  run_native_command([cc.display(), "-O2", "-o", gen.display(), "usr/gen_init_cpio.c"])
  let output = run.capture --bytes $gen "usr/default_cpio_list"

  if ! output.status.ok {
    return Err(kbuild.ScriptError.Failed(kind: "linux-initramfs-default-cpio", message: "gen_init_cpio failed"))
  }

  p"usr/initramfs_inc_data".write(output.stdout)
}
